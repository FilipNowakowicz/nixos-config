-- Behaviour-preserving migration for Hyprland 0.57.
local colors = dofile(os.getenv("HOME") .. "/.config/hypr/colors.lua")
if os.getenv("DESKTOP_TEST") ~= "1" then
	hl.on("hyprland.start", function()
		hl.exec_cmd("hypr-display-mode auto")
	end)
	hl.on("config.reloaded", function()
		-- --verify-config also emits this event, before any output exists.
		if #hl.get_monitors() > 0 then
			hl.exec_cmd("hypr-display-mode auto")
		end
	end)
end
hl.monitor({ output = "", mode = "highrr", position = "auto", scale = 1 })
hl.config({
	input = {
		kb_layout = "us",
		kb_variant = "dvorak",
		follow_mouse = 1,
		sensitivity = 0,
		touchpad = {
			natural_scroll = true,
			tap_to_click = true,
			disable_while_typing = true,
			clickfinger_behavior = true,
			scroll_factor = 0.4,
		},
	},
})
hl.device({
	name = "logitech-usb-receiver",
	sensitivity = -0.2,
	accel_profile = "flat",
})
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.config({
	general = {
		gaps_in = 8,
		gaps_out = 12,
		border_size = 2,
		col = { active_border = colors.active, inactive_border = colors.inactive },
		-- Any edge resizes, as on other desktops. The grab area reaches 15px past it.
		resize_on_border = true,
		-- Floating windows stick to the screen edge and to each other, a gap apart.
		snap = { enabled = true, window_gap = 8, monitor_gap = 12, respect_gaps = true },
	},
})
hl.config({ master = {
	mfact = 0.5,
	new_status = "slave",
} })
-- Without this a split can turn on its side when a neighbour resizes.
hl.config({ dwindle = { preserve_split = true } })
-- A window alone keeps its gaps and rounding but needs no border to show focus.
hl.workspace_rule({ workspace = "w[tv1]", border_size = 0 })
hl.config({
	decoration = {
		rounding = 12,
		-- The inactive border is close to the wallpaper, so a faint dim marks focus too.
		dim_inactive = true,
		dim_strength = 0.05,
		blur = {
			enabled = true,
			size = 4,
			passes = 2,
			new_optimizations = true,
			ignore_opacity = false,
			xray = true,
			vibrancy = 0.17,
			vibrancy_darkness = 0.2,
			noise = 0.012,
		},
		shadow = {
			enabled = true,
			range = 20,
			render_power = 3,
			color = colors.shadow,
		},
	},
})
hl.config({ misc = {
	vrr = 2,
	-- Before the wallpaper unit draws, or while a theme switch restarts it, show the
	-- theme's background instead of a random default wallpaper.
	disable_hyprland_logo = true,
	force_default_wallpaper = 0,
	background_color = colors.background,
} })
hl.config({ animations = {
	enabled = true,
} })
hl.curve("smooth", { type = "bezier", points = { { 0.22, 1.00 }, { 0.36, 1.00 } } })
hl.curve("snappy", { type = "bezier", points = { { 0.16, 1.00 }, { 0.30, 1.00 } } })
hl.curve("spring", { type = "bezier", points = { { 0.18, 0.90 }, { 0.16, 1.05 } } })
hl.curve("momentum", { type = "bezier", points = { { 0.40, 0.00 }, { 0.10, 1.00 } } })
hl.animation({ leaf = "windows", enabled = true, speed = 2.5, bezier = "spring", style = "popin 90%" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.5, bezier = "spring", style = "popin 90%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 2.2, bezier = "smooth", style = "popin 95%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 2.5, bezier = "smooth" })
hl.animation({ leaf = "border", enabled = true, speed = 6, bezier = "smooth" })
hl.animation({ leaf = "fade", enabled = true, speed = 3.0, bezier = "smooth" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 3.0, bezier = "smooth" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 2.5, bezier = "smooth" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 3.0, bezier = "smooth", style = "slidefade 12%" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 3.0, bezier = "momentum", style = "slidevert" })
hl.animation({ leaf = "layers", enabled = true, speed = 3.0, bezier = "smooth", style = "fade" })
-- Desktop mode (SUPER+D) makes windows float, as on macOS or Windows. New windows open
-- in the middle, open ones lift out where they are, and focus follows clicks instead of
-- the pointer. Leaving it tiles everything again except dialogs and tools.
-- It survives a config reload through a file in the runtime dir, but not a logout.
local desktop_state = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-desktop-mode"
local desktop_rule = hl.window_rule({
	name = "desktop-mode",
	enabled = false,
	match = { float = false },
	float = true,
	center = true,
	size = "monitor_w*0.6 monitor_h*0.7",
})
-- Rules declared later win, so the specific ones below override desktop mode.

-- Small tools and dialogs float over the work instead of taking a tile. The keep-float
-- tag leaves them floating when desktop mode ends.
hl.window_rule({
	name = "float-tools",
	match = { class = "^(org\\.pulseaudio\\.pavucontrol|\\.?blueman-manager(-wrapped)?|nm-connection-editor|xdg-desktop-portal-gtk)$" },
	float = true,
	center = true,
	size = "monitor_w*0.45 monitor_h*0.55",
	tag = "+keep-float",
})
-- Notes (SUPER+SHIFT+N) open as a note pad over the work, not a tile.
hl.window_rule({
	name = "float-notes",
	match = { class = "^quiet-notes$" },
	float = true,
	center = true,
	size = "monitor_w*0.4 monitor_h*0.6",
	tag = "+keep-float",
})
hl.window_rule({ name = "float-dialogs", match = { modal = true }, float = true, center = true, tag = "+keep-float" })
hl.window_rule({ name = "float-progress", match = { title = "^File Operation Progress$" }, float = true, tag = "+keep-float" })
-- Picture-in-Picture sits in the corner on every desktop.
hl.window_rule({
	name = "picture-in-picture",
	match = { title = "^Picture-in-Picture$" },
	float = true,
	pin = true,
	keep_aspect_ratio = true,
	size = "monitor_w*0.25 monitor_w*0.140625",
	move = "monitor_w-window_w-24 monitor_h-window_h-24",
	tag = "+keep-float",
})

local function kept_floating(w)
	local tags = type(w.tags) == "table" and table.concat(w.tags, " ") or tostring(w.tags or "")
	return w.pinned or tags:find("keep-float", 1, true) ~= nil
end
-- Floats a window at a comfortable size in the middle of its screen.
local function float_centred(w)
	hl.dispatch(hl.dsp.window.float({ action = "enable", window = w }))
	local m = w.monitor
	if m then
		hl.dispatch(hl.dsp.window.resize({ x = math.floor(m.width / m.scale * 0.6), y = math.floor(m.height / m.scale * 0.7), window = w }))
	end
	hl.dispatch(hl.dsp.window.center({ window = w }))
end

local function apply_desktop(on)
	desktop_rule:set_enabled(on)
	hl.config({ input = { follow_mouse = on and 2 or 1 } })
end
local function xy(v)
	return v.x or v[1], v.y or v[2]
end
local function set_desktop(on)
	apply_desktop(on)
	-- Read every tile before lifting any, since each lift re-tiles the rest.
	local changing = {}
	for _, w in ipairs(hl.get_windows()) do
		if w.floating ~= on and (on or not kept_floating(w)) then
			local x, y = xy(w.at)
			local width, height = xy(w.size)
			changing[#changing + 1] = { w = w, x = x, y = y, width = width, height = height }
		end
	end
	for _, c in ipairs(changing) do
		hl.dispatch(hl.dsp.window.float({ action = on and "enable" or "disable", window = c.w }))
		-- Floating on its own lands at the last floating size, so put it back where it was.
		-- Resize keeps the centre, so it goes first.
		if on then
			hl.dispatch(hl.dsp.window.resize({ x = c.width, y = c.height, window = c.w }))
			hl.dispatch(hl.dsp.window.move({ x = c.x, y = c.y, window = c.w }))
		end
	end
	local f = io.open(desktop_state, "w")
	if f then
		f:write(on and "1" or "0")
		f:close()
	end
	hl.exec_cmd("notify-send -t 1200 Windows '" .. (on and "Desktop: windows float" or "Tiling") .. "'")
end
local function desktop_on()
	return desktop_rule:is_enabled()
end
do
	local f = io.open(desktop_state, "r")
	if f then
		apply_desktop(f:read("a") == "1")
		f:close()
	end
end

-- Apps' own minimise buttons and taskbars ask through this event. Hiding the window on
-- the shell's workspace makes the dock show it as minimised, and click brings it back.
hl.on("window.minimize", function(w, minimized)
	if not w then
		return
	end
	if minimized ~= false then
		hl.dispatch(hl.dsp.window.move({ window = w, workspace = "special:minimized", follow = false }))
	elseif w.workspace and w.workspace.name == "special:minimized" then
		hl.dispatch(hl.dsp.window.move({ window = w, workspace = hl.get_active_workspace().id, follow = true }))
	end
end)

hl.bind("SUPER + Return", hl.dsp.exec_cmd("kitty"))
hl.bind("SUPER + apostrophe", hl.dsp.window.close())
hl.bind("SUPER + b", hl.dsp.exec_cmd("firefox"))
hl.bind("SUPER + BackSpace", hl.dsp.exec_cmd("hyprlock"))
hl.bind("SUPER + Escape", hl.dsp.exec_cmd("quiet-shell-ipc system"))
hl.bind("SUPER + SHIFT + n", hl.dsp.exec_cmd("quiet-shell-ipc notes"))
hl.bind("SUPER + c", hl.dsp.exec_cmd("quiet-shell-ipc controls"))
hl.bind("SUPER + W", hl.dsp.exec_cmd("quiet-shell-ipc pin"))
hl.bind("SUPER + Space", hl.dsp.exec_cmd("quiet-shell-ipc spotlight"))
hl.bind("SUPER + n", hl.dsp.exec_cmd("quiet-shell-ipc notifications"))
hl.bind("SUPER + o", hl.dsp.exec_cmd("quiet-shell-ipc overview"))
hl.bind("SUPER + Tab", hl.dsp.global("quiet-shell:switcher"))
hl.bind("SUPER + SHIFT + Tab", hl.dsp.global("quiet-shell:switcher-back"))
-- Releasing SUPER ends the switcher. The release bind misses it while Tab is still down,
-- which a quick tap often leaves, and the key event alone missed some long holds, so both
-- send it; a second one does nothing. Transparent, or pressing Tab cancels the release.
-- 133 and 134 are the SUPER keys. The switcher leaves the keyboard here, so Escape (9)
-- cancels it this way too.
hl.bind("SUPER + Super_L", hl.dsp.global("quiet-shell:switcher-done"), { release = true, transparent = true })
hl.on("input.keyboard.key", function(keycode, _, pressed)
	if pressed == 0 and (keycode == 133 or keycode == 134) then
		hl.dispatch(hl.dsp.global("quiet-shell:switcher-done"))
	elseif pressed == 1 and keycode == 9 then
		hl.dispatch(hl.dsp.global("quiet-shell:switcher-cancel"))
	end
end)
hl.bind("SUPER + SHIFT + s", hl.dsp.exec_cmd("quiet-shell-ipc screenshot"))
hl.bind("SUPER + slash", hl.dsp.exec_cmd("quiet-shell-ipc shortcuts"))
hl.bind("SUPER + minus", hl.dsp.window.move({ workspace = "special:minimized", follow = false }))
hl.layer_rule({ name = "quiet-glass", match = { namespace = "quiet-shell" }, blur = true, ignore_alpha = 0.02 })
hl.bind("SUPER + M", hl.dsp.exec_cmd("hypr-layout-cycle"))
hl.bind("SUPER + h", hl.dsp.focus({ direction = "left" }))
hl.bind("SUPER + j", hl.dsp.focus({ direction = "down" }))
hl.bind("SUPER + k", hl.dsp.focus({ direction = "up" }))
hl.bind("SUPER + l", hl.dsp.focus({ direction = "right" }))
hl.bind("SUPER + SHIFT + h", hl.dsp.window.move({ direction = "left" }))
hl.bind("SUPER + SHIFT + j", hl.dsp.window.move({ direction = "down" }))
hl.bind("SUPER + SHIFT + k", hl.dsp.window.move({ direction = "up" }))
hl.bind("SUPER + SHIFT + l", hl.dsp.window.move({ direction = "right" }))
hl.bind("SUPER + CTRL + h", hl.dsp.window.resize({ x = -60, y = 0, relative = true }), { repeating = true })
hl.bind("SUPER + CTRL + j", hl.dsp.window.resize({ x = 0, y = 60, relative = true }), { repeating = true })
hl.bind("SUPER + CTRL + k", hl.dsp.window.resize({ x = 0, y = -60, relative = true }), { repeating = true })
hl.bind("SUPER + CTRL + l", hl.dsp.window.resize({ x = 60, y = 0, relative = true }), { repeating = true })
hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
hl.bind("SUPER + 1", hl.dsp.focus({ workspace = 1 }))
hl.bind("SUPER + 2", hl.dsp.focus({ workspace = 2 }))
hl.bind("SUPER + 3", hl.dsp.focus({ workspace = 3 }))
hl.bind("SUPER + 4", hl.dsp.focus({ workspace = 4 }))
hl.bind("SUPER + 5", hl.dsp.focus({ workspace = 5 }))
hl.bind("SUPER + 6", hl.dsp.focus({ workspace = 6 }))
hl.bind("SUPER + 7", hl.dsp.focus({ workspace = 7 }))
hl.bind("SUPER + 8", hl.dsp.focus({ workspace = 8 }))
hl.bind("SUPER + 9", hl.dsp.focus({ workspace = 9 }))
hl.bind("SUPER + 0", hl.dsp.focus({ workspace = 10 }))
hl.bind("SUPER + SHIFT + 1", hl.dsp.window.move({ workspace = 1 }))
hl.bind("SUPER + SHIFT + 2", hl.dsp.window.move({ workspace = 2 }))
hl.bind("SUPER + SHIFT + 3", hl.dsp.window.move({ workspace = 3 }))
hl.bind("SUPER + SHIFT + 4", hl.dsp.window.move({ workspace = 4 }))
hl.bind("SUPER + SHIFT + 5", hl.dsp.window.move({ workspace = 5 }))
hl.bind("SUPER + SHIFT + 6", hl.dsp.window.move({ workspace = 6 }))
hl.bind("SUPER + SHIFT + 7", hl.dsp.window.move({ workspace = 7 }))
hl.bind("SUPER + SHIFT + 8", hl.dsp.window.move({ workspace = 8 }))
hl.bind("SUPER + SHIFT + 9", hl.dsp.window.move({ workspace = 9 }))
hl.bind("SUPER + SHIFT + 0", hl.dsp.window.move({ workspace = 10 }))
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("quiet-shell-ipc brightness 5"))
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("quiet-shell-ipc brightness -5"))
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("quiet-shell-ipc volume 5"))
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("quiet-shell-ipc volume -5"))
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("quiet-shell-ipc mute"))
hl.bind("SUPER + V", hl.dsp.exec_cmd("quiet-shell-ipc clipboard"))
-- Floating lifts the window to the middle at a usable size, so the change is visible.
hl.bind("SUPER + T", function()
	local w = hl.get_active_window()
	if not w then
		return
	end
	if w.floating then
		hl.dispatch(hl.dsp.window.float({ action = "disable", window = w }))
	else
		float_centred(w)
	end
end)
hl.bind("SUPER + D", function()
	set_desktop(not desktop_on())
end)
-- Maximise fills the desktop and keeps the shell; fullscreen covers everything.
hl.bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind("SUPER + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
if os.getenv("DESKTOP_TEST") ~= "1" then
	hl.on("hyprland.start", function()
		hl.exec_cmd(
			"dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_SESSION_TYPE DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE MOZ_ENABLE_WAYLAND NIXOS_OZONE_WL LIBVA_DRIVER_NAME AQ_DRM_DEVICES __GLX_VENDOR_LIBRARY_NAME && systemctl --user start nixos-fake-graphical-session.target"
		)
	end)
end
