# Hyprland image with the ML4W dotfiles (2026-11-15; user's choice)

Dotfiles: mylinuxforwork/dotfiles 2.17 (GPL-3.0; tarball sha256 05c3d87a...). 37 MB of
config + 55 MB of bundled fonts (Fira Code, Fira Sans, Material Icons) + 35 MB wallpapers.
Hyprland 0.57 config is in Lua (hyprland.lua, conf/*.lua), which our 0.57.1 reads.

## Dependencies still to package (tree has: hyprland+libs, kitty, fish, zsh, fastfetch, btop,
htop, imagemagick, tesseract, pavucontrol, network-manager-applet, qt6ct, vlc, firefox, neovim,
tumbler, gvfs, upower, xdg-desktop-portal(-gtk), libadwaita, python-gobject/pillow/pyxdg/requests)
Hypr tools (latest tags): hyprlock 0.9.7, hypridle 0.1.8, hyprpaper 0.8.5, hyprsunset 0.4.0,
 hyprpicker 0.4.8, hyprpolkitagent 0.2.0, hyprshutdown 0.1.2, xdg-desktop-portal-hyprland 1.5.0,
 hyprland-guiutils 0.2.2, hyprtoolkit 0.6.0, hyprland-qt-support 0.1.0, hyprsysteminfo 0.2.0
Shell/UI: waybar 0.16.0, rofi 2.1.1, swaync (SwayNotificationCenter 0.12.6), wlogout,
 quickshell 0.3.2, nwg-look 1.2.1, nwg-displays 0.5.0, awww (swww's successor, Rust),
 matugen 4.2.0 (Rust), cliphist 0.7.0 (Go), grim 1.4.0, slurp 1.5.0, wl-clipboard 2.3.0
Tools: eza 0.23.5, fzf, inotify-tools, udiskie, udisks2, wget, xclip, blueman, nm-connection-editor,
 polkit-gnome, power-profiles-daemon, loupe, nautilus, gnome-text-editor, gnome-themes-extra
Fonts: Fira Code Nerd, JetBrains Mono Nerd, (nerd symbols and noto emoji exist), Material Icons;
 cursor theme (Bibata Modern Ice, used in autostart; ML4W also ships ArcAurora etc. zips).

## Problems to solve in the dotfiles package (no systemd here)
- autostart.lua calls `systemctl --user start xdg-desktop-portal(-hyprland)`, hyprpolkitagent.service,
  and `dbus-update-activation-environment --systemd`: patch to start the programs directly (or via
  dbus activation) from a small session script. uwsm is not used.
- ml4w scripts call pacman/dnf/flatpak/aur helpers (updates, installs): leave but they will not work.
- ML4W Settings / Welcome / Hyprland-settings apps are separate GTK4 apps installed from Flathub by the
  installer: not packaged here (flatpak is available to the user).
- The dotfiles live in ~/.config; ship them as /usr/share/ml4w-dotfiles + /etc/skel copy
  (an image `[[files]]` or skel step is needed; check how dkbuild image builds fill /etc/skel).

## Plan
1. Hypr tools and the small Wayland utilities (grim, slurp, wl-clipboard, cliphist...).
2. waybar, rofi, swaync, wlogout, quickshell, awww, matugen, nwg-*.
3. fonts and cursor, tools; ml4w-dotfiles package (patched); desktop-hyprland-ml4w meta.
4. images/hyprland.toml: greetd (or tty autologin) with session `Hyprland`.
