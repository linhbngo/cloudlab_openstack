#!/usr/bin/env python

import sys

def mask2bits(mask):
    ma = mask.split('.')
    if len(ma) != 4:
        print "ERROR: malformed subnet mask %s" % (mask,)
        sys.exit(1)
    last = 255
    for octet in ma:
        if not octet in ['255','254','252','248','240','224','192','128','0'] \
          or int(octet) > last:
            print "ERROR: malformed subnet mask %s" % (mask,)
            sys.exit(1)
            pass
        last = int(octet)
        pass
    bits = 0
    for octet in ma:
        octet = int(octet)
        if octet == 0:
            break
        for i in range(0,8):
            bits += (1 & octet)
            octet >>= 1
            pass
        pass
    print str(bits)
    return 0

if __name__ == '__main__':
    if sys.argv < 3:
        print "ERROR: must supply at least three arguments!"
        sys.exit(1)
        pass
    if sys.argv[1] == 'mask2bits':
        ret = mask2bits(sys.argv[2])
    else:
        print "ERROR: unsupported subcommand!"
        sys.exit(1)
        pass
    sys.exit(ret)
    pass
