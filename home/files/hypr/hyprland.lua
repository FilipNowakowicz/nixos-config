-- Behaviour-preserving migration for Hyprland 0.57.
local colors = dofile(os.getenv("HOME") .. "/.config/hypr/colors.lua")
-- Written by Home Manager from fleet.quietShell. Missing means the classic shell.
local shell_file = loadfile(os.getenv("HOME") .. "/.config/hypr/shell.lua")
local shell = shell_file and shell_file() or { quiet = false }
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
	},
})
hl.config({ master = {
	mfact = 0.5,
	new_status = "slave",
} })
hl.workspace_rule({ workspace = "w[tv1]", gaps_out = 12, border_size = 0 })
hl.window_rule({ name = "single-window-rounding", match = { workspace = "w[tv1]" }, rounding = 12 })
hl.config({
	decoration = {
		rounding = 12,
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
hl.bind("SUPER + Return", hl.dsp.exec_cmd("kitty"))
hl.bind("SUPER + apostrophe", hl.dsp.window.close())
hl.bind("SUPER + b", hl.dsp.exec_cmd("firefox"))
hl.bind("SUPER + BackSpace", hl.dsp.exec_cmd("hyprlock"))
hl.bind("SUPER + c", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc controls" or "control-center"))
hl.bind("SUPER + W", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc pin" or "waybar-toggle"))
hl.bind("SUPER + Space", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc spotlight" or "launcher"))
if shell.quiet then
	hl.bind("SUPER + n", hl.dsp.exec_cmd("quiet-shell-ipc notifications"))
	hl.bind("SUPER + o", hl.dsp.exec_cmd("quiet-shell-ipc overview"))
	hl.bind("SUPER + Tab", hl.dsp.exec_cmd("quiet-shell-ipc switcher 1"))
	hl.bind("SUPER + SHIFT + Tab", hl.dsp.exec_cmd("quiet-shell-ipc switcher -1"))
	hl.bind("SUPER + Super_L", hl.dsp.exec_cmd("quiet-shell-ipc switcherDone"), { release = true })
	hl.bind("SUPER + SHIFT + s", hl.dsp.exec_cmd("quiet-shell-ipc screenshot"))
	hl.bind("SUPER + slash", hl.dsp.exec_cmd("quiet-shell-ipc shortcuts"))
	hl.bind("SUPER + minus", hl.dsp.window.move({ workspace = "special:minimized", follow = false }))
	hl.layer_rule({ name = "quiet-glass", match = { namespace = "quiet-shell" }, blur = true, ignore_alpha = 0.02 })
end
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
hl.bind("SUPER + CTRL + P", hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))
hl.bind("SUPER + SHIFT + P", hl.dsp.exec_cmd("grim - | wl-copy"))
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc brightness 5" or "swayosd-client --brightness raise"))
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc brightness -5" or "swayosd-client --brightness lower"))
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc volume 5" or "swayosd-client --output-volume raise"))
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc volume -5" or "swayosd-client --output-volume lower"))
hl.bind("XF86AudioMute", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc mute" or "swayosd-client --output-volume mute-toggle"))
hl.bind("SUPER + V", hl.dsp.exec_cmd(shell.quiet and "quiet-shell-ipc clipboard" or "kitty --class clipboard-picker -e clipboard-pick"))
hl.bind("SUPER + T", hl.dsp.window.float({ action = "toggle" }))
if os.getenv("DESKTOP_TEST") ~= "1" then
	hl.on("hyprland.start", function()
		hl.exec_cmd(
			"dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_SESSION_TYPE DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE MOZ_ENABLE_WAYLAND NIXOS_OZONE_WL LIBVA_DRIVER_NAME AQ_DRM_DEVICES __GLX_VENDOR_LIBRARY_NAME && systemctl --user start nixos-fake-graphical-session.target"
		)
		hl.exec_cmd("swaybg -m fill -i ~/.local/share/wallpapers/current.png")
		if not shell.quiet then
			hl.exec_cmd("/run/current-system/sw/libexec/polkit-gnome-authentication-agent-1")
			hl.exec_cmd("control-center --daemon")
		end
	end)
end
