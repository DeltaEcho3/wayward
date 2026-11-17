"""Copies a zip archive without some of its entries, for tools/python_trim.py and tools/omni_trim.py.

Each kept entry's bytes go across as they are (nothing is compressed again), in the same order, and the list at the
end is written from the same fields, so the same archive and the same names always give the same bytes.
"""
import struct
import sys
import zipfile


def copy_without(source, target, names):
    """Writes source to target (which may be source) without the entries named; returns how many were kept."""
    with open(source, "rb") as f:
        data = f.read()
    with zipfile.ZipFile(source) as z:
        infos = sorted(z.infolist(), key=lambda i: i.header_offset)
        directory_start, comment = z.start_dir, z.comment
    if len(infos) >= 0xFFFF or len(data) >= 0xFFFFFFFF:
        sys.exit(f"zip_without: {source} is a zip64 archive, which this does not write")
    out, central, kept = bytearray(), bytearray(), 0
    for k, info in enumerate(infos):
        end = infos[k + 1].header_offset if k + 1 < len(infos) else directory_start
        if info.filename in names:
            continue
        record = data[info.header_offset:end]
        info.header_offset = len(out)
        out += record
        name = info.filename.encode("utf-8" if info.flag_bits & 0x800 else "cp437")
        dos_time = info.date_time[3] << 11 | info.date_time[4] << 5 | info.date_time[5] // 2
        dos_date = (info.date_time[0] - 1980) << 9 | info.date_time[1] << 5 | info.date_time[2]
        central += struct.pack(
            "<4s4B4HL2L5H2L", b"PK\x01\x02", info.create_version, info.create_system, info.extract_version, 0,
            info.flag_bits, info.compress_type, dos_time, dos_date, info.CRC, info.compress_size, info.file_size,
            len(name), len(info.extra), len(info.comment), 0, info.internal_attr, info.external_attr,
            info.header_offset,
        ) + name + info.extra + info.comment
        kept += 1
    end = struct.pack("<4s4H2LH", b"PK\x05\x06", 0, 0, kept, kept, len(central), len(out), len(comment)) + comment
    with open(target, "wb") as f:
        f.write(out + central + end)
    with zipfile.ZipFile(target) as z:
        bad = z.testzip()
        if bad or len(z.infolist()) != kept:
            sys.exit(f"zip_without: {target} did not come out whole ({bad})")
    return kept
