#!/usr/bin/env zsh

setopt errexit pipefail
: ${title:?} ${css:?} ${include:?} ${filter:?}

(( ${#argv} == 2 )) || exit 2

mkdir -p ${2:h}

function run {
    print -Pru2 -- "%F{cyan}${(q-@)argv}%f"
    ${argv} || {
        print -Pru2 -- "%F{red}${argv[1]} failed with exit status ${rc::=$?}%f"
        return ${rc}
    }
    print -Pru2 -- '%F{green}'$'\u2714'" ${argv[1]}%f"$'\n'
}

cmd=(
    pandoc
    --from=markdown
    --lua-filter=${filter}
    --metadata pagetitle=${title}
    --output=${2}
    --section-divs
    --standalone
    --css=${css}
    --include-before-body=${include}
    --to=html
)

run ${cmd} ${1}
