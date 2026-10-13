# tools/oracle_env.sh : the oracle's dependencies and data, for the scripts of tools/ (they source
# it: `. tools/oracle_env.sh`). Each comes from the environment when it is set there.
#
#   PDXORACLE_DEPS      where unicorn and LuaJIT were built (README: Running it), default
#                       ~/pdxoracle-deps: PDXORACLE_UNICORN (libunicorn.so) and luajit on the PATH
#   PDXORACLE_ARCHIVE   the directory of the game's builds: stellaris_backups_steam/by_version/
#                       <depot>/<build>/ and stellaris_backups_gog/<version>/windows/depots/,
#                       default /zpool0/share
#   PDXORACLE_LABELS    stellar-fnmatch's labels (<build id>.csv), for the Windows builds without a
#   PDXORACLE_CORPUS    PDB, and the corpus.json that gives each build id's executable
#                       (oracle/labels.lua); default the match1 run of stellar_except_analysis
#
# PDXORACLE_REPO is the checkout the scripts run: the one this file is in.

PDXORACLE_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${PDXORACLE_DEPS:=$HOME/pdxoracle-deps}"
: "${PDXORACLE_UNICORN:=$PDXORACLE_DEPS/unicorn/build/libunicorn.so}"
: "${PDXORACLE_ARCHIVE:=/zpool0/share}"
: "${PDXORACLE_LABELS:=$PDXORACLE_ARCHIVE/stellar_except_analysis/graph/runs/match1/labels}"
: "${PDXORACLE_CORPUS:=$PDXORACLE_ARCHIVE/stellar_except_analysis/graph/corpus.json}"
case ":$PATH:" in
    *":$PDXORACLE_DEPS/LuaJIT/src:"*) ;;
    *) PATH=$PDXORACLE_DEPS/LuaJIT/src:$PATH ;;
esac
export PDXORACLE_REPO PDXORACLE_DEPS PDXORACLE_UNICORN PDXORACLE_ARCHIVE PDXORACLE_LABELS PDXORACLE_CORPUS PATH
