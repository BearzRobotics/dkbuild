# util-core-default: util-core's commands come before GNU coreutils for every
# login. Remove util-core-default to go back to GNU (which stays installed).
case ":$PATH:" in
*":/usr/lib/util-core/bin:"*) ;;
*) PATH="/usr/lib/util-core/bin:$PATH" ;;
esac
