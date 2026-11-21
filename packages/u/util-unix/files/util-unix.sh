# util-unix-default: util-unix's commands come before the GNU and util-linux versions for every
# login. Remove util-unix-default to go back to GNU (which stays installed).
case ":$PATH:" in
*":/opt/util-unix/bin:"*) ;;
*) PATH="/opt/util-unix/bin:$PATH" ;;
esac
