#!/bin/sed -Enf

1 { 
    x
    i \
#!/bin/bash \

    x
    a \

    p
    x
    i \
set -eE \
set -o pipefail \

    p
}

:header
/^###*/ {
    h
    {
        :wait-for-code
        n
        /^###*/ b header
        /^``` shell/ {
            x
            # Todo: check if we're actually using awscli -- if so, pause, if not -- don't.
            # Added sleep for 10 seconds to allow AWS to settle between operations.
            s/^(##* *)([^\n]*)(.*)/\1\2\3\necho "Performing: \2."\nsleep 10\n/
            p
            x
            :code
            n
            /^```/ {
                a \

                b header
            }
            s/^[$] *//
            s/^export ([^=]*)="([^"]*)" *# *(.*)/: ${\1?"Missing variable: \3 (e.g. \2)"}/
            p
            b code
        }
        s/^/## /
        H
        b wait-for-code
    }
}
