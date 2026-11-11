# zvm (Zig version manager): the Zig chosen with `zvm use` comes first.
# /usr/bin/zig is the system's Zig, the one packages are built with.
export ZVM_INSTALL="$HOME/.zvm/self"
case ":$PATH:" in
*":$HOME/.zvm/bin:"*) ;;
*) PATH="$HOME/.zvm/bin:$PATH" ;;
esac
