local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

-- Requires a wifi chip whose driver can run an access point (see BACKENDS).
-- Currently only tested on Kobo.
if not Device:isKobo() then
    return { disabled = true }
end

-- Supported wifi drivers, keyed by the WIFI_MODULE variable KOReader exports.
local BACKENDS = {
    -- Marvell/NXP 88W8987 (Kobo Clara 2E): the moal driver exposes a uap0 virtual AP interface.
    moal = { iface = "uap0" },
    -- MediaTek MT8113 (Kobo Libra Colour, and likely Clara BW / Clara Colour):
    -- writing "A" to /dev/wmtWifi switches the chip to AP mode and creates ap0,
    -- writing "0" leaves AP mode and powers wifi off (like KOReader's disable-wifi.sh).
    -- The chip cannot be a wifi client and an access point at the same time.
    wlan_drv_gen4m = { iface = "ap0", wmt = "/dev/wmtWifi" },
}
local WIFI_MODULE = os.getenv("WIFI_MODULE")
local BACKEND = WIFI_MODULE and BACKENDS[WIFI_MODULE]

local SENTINEL        = "/tmp/koreader_hotspot_active"
local UDHCPD_PID      = "/tmp/koreader_udhcpd.pid"
local UDHCPD_LEASES   = "/tmp/koreader_udhcpd.leases"
local UDHCPD_CONF     = "/tmp/koreader_udhcpd.conf"
local HOSTAPD_PID     = "/tmp/koreader_hostapd.pid"
local HOSTAPD_CONF    = "/tmp/koreader_hostapd.conf"

local function isModuleLoaded(name)
    local f = io.open("/proc/modules", "r")
    if not f then return false end
    local prefix = name .. " "
    for line in f:lines() do
        if line:sub(1, #prefix) == prefix then
            f:close()
            return true
        end
    end
    f:close()
    return false
end

-- Sends a one-character command ("A" or "0") to the MediaTek wifi control device.
local function writeWmt(cmd)
    local f = io.open(BACKEND.wmt, "w")
    if not f then
        logger.warn("Hotspot: cannot open", BACKEND.wmt)
        return false
    end
    f:write(cmd)
    local ok, err = f:close()
    if not ok then
        logger.warn("Hotspot: writing", cmd, "to", BACKEND.wmt, "failed:", err)
        return false
    end
    return true
end

local Hotspot = WidgetContainer:extend{
    name = "hotspot",
    is_doc_only = false,
}

function Hotspot:init()
    self.ssid     = G_reader_settings:readSetting("hotspot_ssid")     or "KoboAP"
    self.channel  = G_reader_settings:readSetting("hotspot_channel")  or "6"
    self.security = G_reader_settings:readSetting("hotspot_security") or "open"
    self.password = G_reader_settings:readSetting("hotspot_password") or ""
    self.autostart = G_reader_settings:isTrue("hotspot_autostart")

    if self.autostart then
        self:start()
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function Hotspot:isRunning()
    return util.pathExists(SENTINEL)
end

-- Polls up to 5 s for the AP interface to appear.
function Hotspot:waitForInterface()
    local sysfs = "/sys/class/net/" .. BACKEND.iface
    for _ = 1, 20 do
        ffiutil.sleep(0.25)
        if util.pathExists(sysfs) then
            return true
        end
    end
    return false
end

-- Loads the wifi kernel module (if not already loaded) without triggering
-- NetworkMgr's network scan / connection attempt.
function Hotspot:ensureModuleLoaded()
    if util.pathExists("/sys/class/net/" .. BACKEND.iface) then
        return true
    end
    logger.info("Hotspot: wifi module not loaded, running enable-wifi.sh")
    os.execute("./enable-wifi.sh")
    return self:waitForInterface()
end

local function isRunningProcess(name)
    return os.execute("pidof " .. name .. " >/dev/null 2>&1") == 0
end

-- MediaTek: when Nickel first turns wifi on after boot, it also starts the
-- wmt_loader and wmt_launcher firmware daemons. KOReader's enable-wifi.sh does not,
-- and powering the chip without them reboots the Kobo
-- (koreader/koreader#13197, fix from koreader/koreader#16222).
-- Starts them like Nickel does. Returns false if that is not possible.
function Hotspot:startMediatekDaemons()
    if isRunningProcess("wmt_launcher") then
        return true
    end
    if not (util.pathExists("/usr/bin/wmt_loader") and util.pathExists("/usr/bin/wmt_launcher")) then
        logger.warn("Hotspot: wmt_loader/wmt_launcher not found")
        return false
    end
    logger.info("Hotspot: starting wmt_loader and wmt_launcher")
    if not isModuleLoaded("wmt_drv") then
        os.execute(string.format("insmod /drivers/%s/mt66xx/wmt_drv.ko", os.getenv("PLATFORM") or ""))
    end
    if not isRunningProcess("wmt_loader") then
        os.execute("/usr/bin/wmt_loader >/dev/null 2>&1 &")
    end
    os.execute("/usr/bin/wmt_launcher -p /lib/firmware >/dev/null 2>&1 &")
    -- Give the daemons time to settle before the chip is powered on.
    for _ = 1, 12 do
        ffiutil.sleep(0.25)
        if isRunningProcess("wmt_launcher") then
            ffiutil.sleep(1)
            return true
        end
    end
    logger.warn("Hotspot: wmt_launcher did not start")
    return false
end

-- MediaTek: the wifi modules are loaded once and never unloaded. If nothing
-- has loaded them since boot, start the firmware daemons, then cycle
-- KOReader's own wifi scripts once.
function Hotspot:ensureMediatekModulesLoaded()
    if isModuleLoaded(WIFI_MODULE) and isRunningProcess("wmt_launcher") then
        return true
    end
    local msg = InfoMessage:new{
        text = _("Loading Wi-Fi modules…"),
    }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok = self:startMediatekDaemons()
    if ok then
        logger.info("Hotspot: wifi modules not loaded, cycling enable-wifi.sh and disable-wifi.sh")
        os.execute("./enable-wifi.sh")
        os.execute("./disable-wifi.sh")
        ok = isModuleLoaded(WIFI_MODULE)
    end
    UIManager:close(msg)
    if not ok then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Hotspot: Wi-Fi has not been started since the Kobo restarted.\n\nTurn on Wi-Fi once from the Kobo home screen, then try again."),
        })
    end
    return ok
end

-- Makes the AP interface available.
-- Returns ok, and whether a failure was already reported to the user.
function Hotspot:bringUpInterface()
    if not BACKEND.wmt then
        return self:ensureModuleLoaded()
    end
    if not self:ensureMediatekModulesLoaded() then
        return false, true
    end
    if util.pathExists("/sys/class/net/" .. BACKEND.iface) then
        return true
    end
    logger.info("Hotspot: switching the MediaTek chip to AP mode")
    if not writeWmt("A") then
        return false
    end
    return self:waitForInterface()
end

-- MediaTek: a failed start must not leave the chip in AP mode
-- (KOReader would then believe wifi is on).
function Hotspot:abortStart()
    if BACKEND.wmt then
        self:stopHostapd()
        writeWmt("0")
    end
end

function Hotspot:startHostapd()
    local bin = self.path .. "/hostapd"
    if not util.pathExists(bin) then
        logger.warn("Hotspot: no hostapd binary found")
        return false
    end

    local f = io.open(HOSTAPD_CONF, "w")
    if not f then return false end

    local conf = string.format(
        "interface=%s\n"      ..
        "driver=nl80211\n"    ..
        "ssid=%s\n"           ..
        "hw_mode=g\n"         ..
        "channel=%s\n"        ..
        "ignore_broadcast_ssid=0\n",
        BACKEND.iface, self.ssid, self.channel)

    if self.security == "wpa2" and self.password ~= "" then
        conf = conf .. string.format(
            "wpa=2\n"                    ..
            "wpa_passphrase=%s\n"        ..
            "wpa_key_mgmt=WPA-PSK\n"     ..
            "rsn_pairwise=CCMP\n",
            self.password)
    end

    f:write(conf)
    f:close()

    -- hostapd daemonizes itself; -B runs in background, -P writes the pid file
    local rc = os.execute(string.format(
        "%s -B -P %s %s", bin, HOSTAPD_PID, HOSTAPD_CONF))
    if rc ~= 0 then
        logger.warn("Hotspot: hostapd failed to start")
        return false
    end
    -- give it a moment to bring the interface up before we assign an IP
    ffiutil.sleep(1)
    return true
end

function Hotspot:stopHostapd()
    local f = io.open(HOSTAPD_PID, "r")
    if not f then return end
    local pid = f:read("*l")
    f:close()
    if pid then
        os.execute("kill " .. pid .. " 2>/dev/null")
    end
    os.remove(HOSTAPD_PID)
    os.remove(HOSTAPD_CONF)
end

function Hotspot:startDHCP()
    local bin = self.path .. "/udhcpd"
    if not util.pathExists(bin) then
        logger.info("Hotspot: no udhcpd binary found, skipping DHCP")
        return
    end
    local f = io.open(UDHCPD_CONF, "w")
    if not f then return end
    f:write(string.format(
        "start         192.168.42.10\n"  ..
        "end           192.168.42.100\n" ..
        "interface     %s\n"             ..
        "pidfile       %s\n"             ..
        "lease_file    %s\n"             ..
        "option subnet 255.255.255.0\n"  ..
        "option router 192.168.42.1\n"   ..
        "option dns    8.8.8.8\n"        ..
        "option lease  3600\n",
        BACKEND.iface, UDHCPD_PID, UDHCPD_LEASES))
    f:close()
    os.execute(string.format("%s %s", bin, UDHCPD_CONF))
    logger.info("Hotspot: udhcpd started")
end

function Hotspot:stopDHCP()
    local f = io.open(UDHCPD_PID, "r")
    if not f then return end
    local pid = f:read("*l")
    f:close()
    if pid then
        os.execute("kill " .. pid .. " 2>/dev/null")
    end
    os.remove(UDHCPD_PID)
    os.remove(UDHCPD_CONF)
end

-- `done` (optional) runs once the hotspot has started or failed to, e.g. to refresh the menu.
function Hotspot:start(done)
    if self:isRunning() then return end

    if not BACKEND then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Hotspot: this Kobo's Wi-Fi chip (%1) is not supported yet."), WIFI_MODULE or _("unknown")),
        })
        return
    end

    -- MediaTek: the chip cannot be a wifi client and an access point at the same time.
    if BACKEND.wmt and NetworkMgr:isWifiOn() then
        UIManager:show(ConfirmBox:new{
            text = _("The hotspot cannot run while Wi-Fi is on.\n\nTurn off Wi-Fi and start the hotspot?"),
            ok_text = _("Turn off Wi-Fi and start hotspot"),
            ok_callback = function()
                NetworkMgr:toggleWifiOff(function()
                    UIManager:nextTick(function()
                        self:startHotspot()
                        if done then done() end
                    end)
                end, true)
            end,
        })
        return
    end

    self:startHotspot()
    if done then done() end
end

function Hotspot:startHotspot()
    local ok, reported = self:bringUpInterface()
    if not ok then
        if reported then return end
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Hotspot: %1 interface not found."), BACKEND.iface),
        })
        return
    end

    logger.info("Hotspot: starting — SSID:", self.ssid, "channel:", self.channel)

    os.execute("ip addr flush dev " .. BACKEND.iface .. " 2>/dev/null")

    if not self:startHostapd() then
        self:abortStart()
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Hotspot: failed to start hostapd. Is the binary installed in the plugin directory?"),
        })
        return
    end

    local rc = os.execute("ip addr add 192.168.42.1/24 dev " .. BACKEND.iface)

    if rc == 0 then
        local f = io.open(SENTINEL, "w")
        if f then f:close() end
        self:startDHCP()

        UIManager:show(InfoMessage:new{
            timeout = 6,
            text = T(_("Hotspot started.\n\nSSID: %1\nIP address: 192.168.42.1"), self.ssid),
        })
    else
        self:abortStart()
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Hotspot: one or more commands failed. Check the logs."),
        })
    end
end

-- `done` (optional) runs once the hotspot has stopped, e.g. to refresh the menu.
function Hotspot:stop(done)
    if not self:isRunning() then return end

    logger.info("Hotspot: stopping")
    self:stopDHCP()
    self:stopHostapd()
    os.execute("ip addr flush dev " .. BACKEND.iface .. " 2>/dev/null")

    if not BACKEND.wmt then
        os.execute("ip link set " .. BACKEND.iface .. " down")
        os.remove(SENTINEL)
        if done then done() end
        UIManager:show(InfoMessage:new{
            text = _("Hotspot stopped."),
            timeout = 2,
        })
        return
    end

    -- MediaTek: leaving AP mode powers wifi off.
    writeWmt("0")
    os.remove(SENTINEL)
    if done then done() end
    UIManager:show(ConfirmBox:new{
        text = _("Hotspot stopped. Wi-Fi is off."),
        ok_text = _("Turn on Wi-Fi"),
        cancel_text = _("Keep Wi-Fi off"),
        ok_callback = function()
            NetworkMgr:toggleWifiOn(nil, false, true)
        end,
    })
end

function Hotspot:onToggleHotspot(done)
    if self:isRunning() then
        self:stop(done)
    else
        self:start(done)
    end
end

function Hotspot:showSsidDialog(touchmenu_instance)
    self.ssid_dialog = InputDialog:new{
        title = _("Hotspot SSID"),
        input = self.ssid,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(self.ssid_dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local v = self.ssid_dialog:getInputText()
                    if v and v ~= "" then
                        self.ssid = v
                        G_reader_settings:saveSetting("hotspot_ssid", v)
                        UIManager:close(self.ssid_dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end
                end,
            },
        }},
    }
    UIManager:show(self.ssid_dialog)
    self.ssid_dialog:onShowKeyboard()
end

function Hotspot:showPasswordDialog(touchmenu_instance)
    self.pw_dialog = InputDialog:new{
        title = _("WPA2 password"),
        input = self.password,
        text_type = "password",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(self.pw_dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local v = self.pw_dialog:getInputText()
                    if v and #v >= 8 then
                        self.password = v
                        G_reader_settings:saveSetting("hotspot_password", v)
                        UIManager:close(self.pw_dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    else
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = _("WPA2 password must be at least 8 characters."),
                            timeout = 3,
                        })
                    end
                end,
            },
        }},
    }
    UIManager:show(self.pw_dialog)
    self.pw_dialog:onShowKeyboard()
end

local CHANNELS = {"1", "6", "11"}

function Hotspot:addToMainMenu(menu_items)
    local channel_items = {}
    for _i, ch in ipairs(CHANNELS) do
        table.insert(channel_items, {
            text = T(_("Channel %1"), ch),
            checked_func = function() return self.channel == ch end,
            callback = function()
                self.channel = ch
                G_reader_settings:saveSetting("hotspot_channel", ch)
            end,
        })
    end

    menu_items.hotspot = {
        text = _("Wi-Fi hotspot"),
        sorting_hint = "network",
        checked_func = function() return self:isRunning() end,
        sub_item_table = {
            {
                text = _("Enable hotspot"),
                checked_func = function() return self:isRunning() end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    -- On MediaTek, starting can wait for a confirmation dialog,
                    -- so refresh the menu when the toggle completes.
                    self:onToggleHotspot(function()
                        touchmenu_instance:updateItems()
                    end)
                end,
            },
            {
                text_func = function()
                    return T(_("SSID: %1"), self.ssid)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:showSsidDialog(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("Channel: %1"), self.channel)
                end,
                enabled_func = function() return not self:isRunning() end,
                sub_item_table = channel_items,
            },
            {
                text = _("Open network (no password)"),
                checked_func = function() return self.security == "open" end,
                enabled_func = function() return not self:isRunning() end,
                callback = function()
                    self.security = "open"
                    G_reader_settings:saveSetting("hotspot_security", "open")
                end,
            },
            {
                text = _("WPA2 password protection"),
                checked_func = function() return self.security == "wpa2" end,
                enabled_func = function() return not self:isRunning() end,
                callback = function()
                    self.security = "wpa2"
                    G_reader_settings:saveSetting("hotspot_security", "wpa2")
                end,
            },
            {
                text_func = function()
                    local masked = self.password ~= "" and string.rep("*", #self.password) or _("(not set)")
                    return T(_("WPA2 password: %1"), masked)
                end,
                keep_menu_open = true,
                enabled_func = function()
                    return self.security == "wpa2" and not self:isRunning()
                end,
                callback = function(touchmenu_instance)
                    self:showPasswordDialog(touchmenu_instance)
                end,
            },
            {
                text = _("Start hotspot with KOReader"),
                checked_func = function() return self.autostart end,
                callback = function()
                    self.autostart = not self.autostart
                    G_reader_settings:flipNilOrFalse("hotspot_autostart")
                end,
            },
        },
    }
end

function Hotspot:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_hotspot", {
        category = "none",
        event    = "ToggleHotspot",
        title    = _("Toggle Wi-Fi hotspot"),
        general  = true,
    })
end

return Hotspot
