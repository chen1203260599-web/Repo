#!/usr/bin/env python3
"""Summarize packet metadata from a PCAP/PCAPNG using tshark.

Requires Wireshark's tshark command. Payload contents are not printed.
Usage:
  python3 analyze_pcap.py capture.pcapng
  python3 analyze_pcap.py capture.pcapng --phone 192.168.1.20 --box 192.168.1.30
"""
import argparse
import csv
import shutil
import subprocess
import sys

FIELDS = [
    "frame.time_epoch", "ip.src", "ipv6.src", "ip.dst", "ipv6.dst",
    "frame.protocols", "frame.len", "udp.srcport", "udp.dstport",
    "tcp.srcport", "tcp.dstport", "dns.qry.name",
]
MULTICAST_OR_BROADCAST = {
    "255.255.255.255", "224.0.0.251", "239.255.255.250",
    "ff02::fb", "ff02::c",
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcap")
    parser.add_argument("--phone", help="phone IP address")
    parser.add_argument("--box", help="bridge box IP address")
    args = parser.parse_args()

    if bool(args.phone) != bool(args.box):
        parser.error("--phone and --box must be supplied together")

    tshark = shutil.which("tshark")
    if not tshark:
        sys.exit("ERROR: tshark not found. Install Wireshark/tshark first.")

    cmd = [tshark, "-r", args.pcap, "-T", "fields",
           "-E", "separator=/t", "-E", "quote=d", "-E", "occurrence=f"]
    for field in FIELDS:
        cmd += ["-e", field]

    try:
        raw = subprocess.check_output(cmd, stderr=subprocess.PIPE, text=True)
    except subprocess.CalledProcessError as exc:
        sys.exit("ERROR reading capture: " + exc.stderr.strip())

    reader = csv.reader(raw.splitlines(), delimiter="\t", quotechar='"')
    print("\t".join(FIELDS))
    for row in reader:
        row += [""] * (len(FIELDS) - len(row))
        src = row[1] or row[2]
        dst = row[3] or row[4]
        if args.phone and args.box:
            direct_pair = ((src == args.phone and dst == args.box) or
                           (src == args.box and dst == args.phone))
            discovery_multicast = dst in MULTICAST_OR_BROADCAST
            if not (direct_pair or discovery_multicast):
                continue
        print("\t".join(value.replace("\t", " ") for value in row[:len(FIELDS)]))

if __name__ == "__main__":
    main()
