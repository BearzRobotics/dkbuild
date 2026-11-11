# rustup: once a toolchain is set up (`rustup default stable` makes ~/.rustup),
# its cargo, rustc, rustfmt, ... come first, and so do programs from
# `cargo install` (~/.cargo/bin). Before that, /usr/bin/cargo is the system's
# Rust, the one packages are built with.
if [ -d "$HOME/.rustup" ]; then
    case ":$PATH:" in
    *":/usr/lib/rustup/bin:"*) ;;
    *) PATH="$HOME/.cargo/bin:/usr/lib/rustup/bin:$PATH" ;;
    esac
fi
