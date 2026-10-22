"""Select the WPS geography tar members that cover a lat/lon box.

  geog_subset.py <members.txt> <dir with extracted */index files> S W N E  > keep.txt

members.txt is `tar tzf` of the geography tarball. Prints every index file, plus for each
regular_ll dataset the tiles (XXXXX-XXXXX.YYYYY-YYYYY, 1-based grid indices) whose extent
overlaps the box. Members of datasets in any other projection are all kept.
"""
import os
import re
import sys

TILE = re.compile(r"^(\d+)-(\d+)\.(\d+)-(\d+)$")


def parse_index(path):
    kv = {}
    for line in open(path, errors="replace"):
        line = line.split("#")[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip().lower()] = v.strip().strip('"')
    return kv


def main():
    members_txt, root = sys.argv[1], sys.argv[2]
    s, w, n, e = map(float, sys.argv[3:7])
    members = [m.strip() for m in open(members_txt) if m.strip() and not m.strip().endswith("/")]
    datasets = {}
    for m in members:
        if os.path.basename(m) == "index":
            datasets[os.path.dirname(m)] = parse_index(os.path.join(root, m))
    for m in members:
        d, name = os.path.dirname(m), os.path.basename(m)
        kv = datasets.get(d)
        if kv is None:
            continue                       # not inside a dataset directory (e.g. README files)
        if name == "index" or kv.get("projection") != "regular_ll":
            print(m)
            continue
        t = TILE.match(name)
        if not t:
            print(m)
            continue
        i0, i1, j0, j1 = map(int, t.groups())
        dx, dy = float(kv["dx"]), float(kv["dy"])
        kx, ky = float(kv.get("known_x", 1)), float(kv.get("known_y", 1))
        klat, klon = float(kv["known_lat"]), float(kv["known_lon"])
        lat0, lat1 = sorted((klat + (j0 - ky) * dy, klat + (j1 - ky) * dy))
        if lat1 < s or lat0 > n:
            continue
        lon0, lon1 = klon + (i0 - kx) * dx, klon + (i1 - kx) * dx
        if any(lon1 + sh >= w and lon0 + sh <= e for sh in (-360, 0, 360)):
            print(m)


main()
