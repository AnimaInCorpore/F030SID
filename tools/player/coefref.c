/* The filter coefficient words of sid_filter_coeffs() for every <step>th fc and
 * every res, both models: the expected output of src/m68k/coeftest.s. */
#include "sid_ref.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    int step = argc > 1 ? atoi(argv[1]) : 3, m;
    unsigned fc, res;

    for (m = 0; m < 2; m++)
        for (fc = 0; fc < 2048; fc += (unsigned)step)
            for (res = 0; res < 16; res++) {
                sid_filter_coeffs_t c;
                sid_filter_coeffs((sid_model_t)m, fc, res, &c);
                printf("%u %u %u %u %u %u %u %u\n", (unsigned)c.a1, (unsigned)c.a2, (unsigned)c.a3, (unsigned)c.k4,
                       (unsigned)c.wl, (unsigned)c.wb, (unsigned)c.wh, (unsigned)c.wleak);
            }
    return 0;
}
