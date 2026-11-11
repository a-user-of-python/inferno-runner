#!/bin/bash
# Inferno jailbroken guest-image builder — Intel Mac, NO Homebrew.
# Pipeline: CLT check -> Docker (Linux builder) -> IPSW -> tickets -> SEP repack
# -> disks -> Debian companion VM -> two-VM idevicerestore restore -> macOS APFS
# patches + checkra1n bootstrap -> migration boot -> exact InfernoData.zip layout.
# Resumable: re-paste the same block after any stop; finished stages are skipped.
set -u
W="$HOME/InfernoMacBuild"; DATA="$W/data"; SRC="$W/src"; LOGS="$W/logs"
mkdir -p "$W" "$DATA/Restore" "$SRC" "$LOGS" "$W/companion" "$W/keys" "$W/run" "$W/pkg"
IPSW_URL="https://updates.cdn-apple.com/2020SummerSeed/fullrestores/001-35886/5FE9BE2E-17F8-41C8-96BB-B76E2B225888/iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw"
IPSW_SHA="706742ed60327a5247c29ccc5bf7e6ce9bbf11dd30a468f8f6fc9da76bdca96d"
say(){ printf '\n=== %s ===\n' "$*"; }
die(){ printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
ck(){ [ -e "$1" ] || die "missing expected file: $1"; }
cksz(){ [ -f "$1" ] && [ "$(stat -f%z "$1" 2>/dev/null || stat -c%s "$1")" = "$2" ] || die "size check failed: $1 (want $2 bytes)"; }

# ---------- 1. Apple Command Line Tools (Apple's own, not Homebrew) ----------
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  echo "Finish the Command Line Tools install dialog, then paste this same block again."
  exit 0
fi

# ---------- 2. Inputs only a human can supply ----------
# 2a. SEP ROM (86,016 B): download the T8030 "Cebu B1" SEPROM from https://securerom.fun
#     (Darwin section) once, into ~/Downloads. No direct file URL is published.
if [ ! -f "$DATA/AppleSEPROM-Cebu-B1" ]; then
  for c in "$HOME/Downloads/AppleSEPROM-Cebu-B1" "$W/AppleSEPROM-Cebu-B1"; do
    [ -f "$c" ] && cp "$c" "$DATA/AppleSEPROM-Cebu-B1" && break
  done
fi
[ -f "$DATA/AppleSEPROM-Cebu-B1" ] || die "Put AppleSEPROM-Cebu-B1 (from securerom.fun, T8030 Cebu B1) in ~/Downloads first."
cksz "$DATA/AppleSEPROM-Cebu-B1" 86016
# 2b. SEP firmware IV+Key: public firmware keys for iPhone12,1 / 18A5351d (The Apple Wiki).
#     Pasted once, stored only in this local work folder, never uploaded.
if [ ! -s "$W/sepkey.txt" ]; then
  printf 'Paste the SEP IV+Key for iPhone12,1 18A5351d (96 hex chars, IV then key, no spaces): '
  read -r SEPKEY; echo "$SEPKEY" > "$W/sepkey.txt"
fi
SEPKEY="$(tr -d ' \n' < "$W/sepkey.txt")"
[ "${#SEPKEY}" = 96 ] || die "SEP key must be 96 hex chars (got ${#SEPKEY}). Fix $W/sepkey.txt."
[ -f "$W/keys/id_ed25519" ] || ssh-keygen -t ed25519 -N '' -f "$W/keys/id_ed25519" >/dev/null

# ---------- 3. Docker Desktop (official Intel dmg; first launch is interactive) ----------
if ! command -v docker >/dev/null 2>&1 && [ ! -d /Applications/Docker.app ]; then
  say "Installing Docker Desktop (Intel)"
  curl -L -o "$W/Docker.dmg" "https://desktop.docker.com/mac/main/amd64/Docker.dmg" || die "Docker download failed"
  hdiutil attach "$W/Docker.dmg" -nobrowse -quiet || die "Docker dmg mount failed"
  sudo cp -R "/Volumes/Docker/Docker.app" /Applications/ || die "Docker app copy failed"
  hdiutil detach "/Volumes/Docker" -quiet || true
fi
open -a Docker || true
say "Waiting for Docker (complete its first-run prompts, incl. password, if shown)"
until docker info >/dev/null 2>&1; do sleep 5; done

# ---------- 4. Builder container (Debian + all deps; nettle 3.10.2 + lzfse from source) ----------
cat > "$W/Dockerfile" <<'EOF'
FROM debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential git curl ca-certificates meson ninja-build pkg-config python3 python3-pyasn1 python3-pyasn1-modules \
  unzip zip genisoimage openssh-client netcat-openbsd file cmake gperf bison flex \
  autoconf automake libtool gettext autopoint libglib2.0-dev libpixman-1-dev libslirp-dev \
  libgnutls28-dev libfdt-dev libusb-1.0-0-dev libpng-dev libjpeg62-turbo-dev zlib1g-dev \
  libbz2-dev liblzma-dev libzstd-dev libcurl4-openssl-dev libssl-dev libplist-dev \
  libzip-dev libreadline-dev libgmp-dev libncurses-dev && rm -rf /var/lib/apt/lists/*
RUN curl -LO https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz || \
    curl -LO https://mirrors.kernel.org/gnu/nettle/nettle-3.10.2.tar.gz; \
  tar xf nettle-3.10.2.tar.gz && cd nettle-3.10.2 && ./configure --prefix=/usr/local \
  --disable-documentation && make -j"$(nproc)" && make install && ldconfig && cd / && rm -rf nettle-3.10.2*
RUN git clone --depth 1 https://github.com/lzfse/lzfse /tmp/lzfse && cmake -S /tmp/lzfse -B /tmp/lzfse/b \
  -DCMAKE_INSTALL_PREFIX=/usr/local && cmake --build /tmp/lzfse/b -j"$(nproc)" && \
  cmake --install /tmp/lzfse/b && ldconfig && rm -rf /tmp/lzfse
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip \
  && pip3 install --break-system-packages "meson>=1.5,<2" && rm -rf /var/lib/apt/lists/*
WORKDIR /work
EOF
docker build -t inferno-builder "$W" || die "docker build failed"
docker rm -f inferno1 >/dev/null 2>&1 || true
docker run -d --name inferno1 -v "$W:/work" inferno-builder sleep infinity >/dev/null || die "container start failed"
DEX(){ docker exec inferno1 bash -lc "$*"; }

# ---------- 5. Sources: Inferno emulator, ticket tools, img4 ----------
DEX 'set -e; cd /work/src
[ -d Inferno ] || git clone --depth 1 https://github.com/ChefKissInc/Inferno Inferno
git -C Inferno submodule update --init --depth 1 $(git -C Inferno config -f .gitmodules --get-regexp path | sed "s/.* //" | grep -v "^roms/")
[ -d tools ] || git clone --depth 1 https://github.com/TrungNguyen1909/qemu-t8030-tools tools
[ -d img4lib ] || git clone --recurse-submodules https://github.com/xerub/img4lib img4lib
for r in libplist libimobiledevice-glue libtatsu libusbmuxd libimobiledevice usbmuxd libirecovery; do
  [ -d limd/$r ] || git clone --depth 1 https://github.com/libimobiledevice/$r limd/$r
done
[ -d limd/idevicerestore ] || git clone --depth 1 https://github.com/TrungNguyen1909/idevicerestore limd/idevicerestore
git -C limd/idevicerestore fetch -q --depth 1 origin 60192e97f87d1bbab5c493684e0a245b0966363f && git -C limd/idevicerestore checkout -q FETCH_HEAD
[ "$(git -C limd/idevicerestore rev-parse HEAD)" = "60192e97f87d1bbab5c493684e0a245b0966363f" ] || fail "idevicerestore is not at the pinned revision"
echo "Inferno HEAD: $(git -C Inferno rev-parse HEAD)"' || die "source fetch failed"

# ---------- 6. Build the emulator (aarch64 guest + x86_64 companion) + img4 ----------
DEX 'set -e; cd /work/src; export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig
[ -x Inferno/build/qemu-system-aarch64 ] || {
  mkdir -p Inferno/build
  (cd Inferno/build && ../configure --target-list=aarch64-softmmu,x86_64-softmmu \
    --enable-nettle --enable-gnutls --enable-slirp --enable-libusb --enable-png \
    --enable-bzip2 --enable-lzfse --disable-werror)
  ninja -C Inferno/build qemu-system-aarch64 qemu-system-x86_64 qemu-img; }
[ -x img4lib/img4 ] || make -C img4lib -j"$(nproc)"
Inferno/build/qemu-system-aarch64 --version | head -1' || die "emulator build failed"
QB="/work/src/Inferno/build"

# ---------- 7. IPSW: download from Apple, verify, extract ----------
DEX 'set -e; cd /work
[ -f ipsw.ipsw ] || curl -L -C - -o ipsw.ipsw "'"$IPSW_URL"'"
[ "$(stat -c%s ipsw.ipsw)" = 5507405643 ] || { echo "IPSW size mismatch"; exit 1; }
[ "$(sha256sum ipsw.ipsw | cut -d" " -f1)" = "'"$IPSW_SHA"'" ] || { echo "IPSW sha256 mismatch"; exit 1; }
[ -f ipsw-x/BuildManifest.plist ] || { mkdir -p ipsw-x && unzip -o -q ipsw.ipsw -d ipsw-x; }
D=/work/data; R=$D/Restore; mkdir -p $R/Firmware/all_flash
cp ipsw-x/kernelcache.release.iphone12b $R/
cp ipsw-x/kernelcache.research.iphone12b $R/
cp ipsw-x/Firmware/038-44135-124.dmg.trustcache $R/Firmware/
cp ipsw-x/Firmware/all_flash/DeviceTree.n104ap.im4p $R/Firmware/all_flash/
cp ipsw-x/038-44135-124.dmg $R/' || die "IPSW stage failed"

# create_septicket.py is NOT in qemu-t8030-tools (verified 2026-11-10 against the
# repo's master tree via the GitHub API) so step 8's call to it would fail.
# Embed the September-proven copy instead: run locally it regenerates the
# known-good sep_root_ticket.der byte-for-byte (8,931 bytes).
if [ ! -f "$SRC/tools/bootstrap_scripts/create_septicket.py" ]; then
  mkdir -p "$SRC/tools/bootstrap_scripts"
  cat > "$SRC/tools/bootstrap_scripts/create_septicket.py" <<'PYEOF_SEP'
#!/usr/bin/env python3

# adapted from create_apticket.py

import plistlib
import sys
from binascii import hexlify

from pyasn1.codec.der.decoder import decode
from pyasn1.codec.der.encoder import encode
from pyasn1.type.char import IA5String
from pyasn1.type.namedtype import NamedType, NamedTypes
from pyasn1.type.tag import Tag, tagClassPrivate, tagFormatConstructed, tagFormatSimple
from pyasn1.type.univ import Integer, OctetString, Sequence, SequenceOf, Set, SetOf
from pyasn1_modules import rfc5280


class APTicketMANB(Sequence):
    componentType = NamedTypes(
        NamedType("type", IA5String()),
        NamedType("payload", Set()),
    )
    tagSet = Sequence.tagSet.tagExplicitly(
        Tag(tagClassPrivate, tagFormatConstructed, 0x4D414E42)
    )


class APTicket(Sequence):
    componentType = NamedTypes(
        NamedType("type", IA5String()),
        NamedType("ver", Integer()),
        NamedType("manb", SetOf(APTicketMANB())),
        NamedType("unk", OctetString()),
        NamedType("cert", SequenceOf(rfc5280.Certificate())),
    )


def find_build_identity(manifest, model):
    for identity in manifest["BuildIdentities"]:
        if (
            identity["Info"]["DeviceClass"] == model
            and "RestoreBehavior" in identity["Info"]
            and identity["Info"]["RestoreBehavior"] == "Erase"
        ):
            return identity
    return None


def create_seq(name, value):
    name_hex_int = int(hexlify(name.encode()), 16)
    seq = Sequence().subtype(
        explicitTag=Tag(tagClassPrivate, tagFormatSimple, name_hex_int)
    )
    seq.setComponentByPosition(0, IA5String(name))
    seq.setComponentByPosition(1, value)
    return seq


man_key_map = {
    "rosi": "OS",
    "krnl": "KernelCache",
    "dtre": "DeviceTree",
    "rdtr": "RestoreDeviceTree",
    "trst": "StaticTrustCache",
    "rtsc": "RestoreTrustCache",
    "sepi": "SEP",
    "rsep": "RestoreSEP",
}


def modifying_func(plist, b, chip_id, mod_ecid_snon=True):
    for i in range(len(b)):
        man_4cc = b[i][0]
        key = man_key_map.get(man_4cc)
        if key is not None:
            b[i][1][0][1] = plist["Manifest"][key]["Digest"]
        elif b[i][0] in ("rfta", "ftap", "rfts", "ftsp"):
            b[i][0] = b[i][0][::-1]
        elif b[i][0] == "MANP":
            manp = b[i][1]
            for j in range(len(manp)):
                if manp[j][0] == "CHIP":
                    manp[j][1] = chip_id
                elif mod_ecid_snon:
                    if manp[j][0] == "ECID":
                        manp[j][1] = 0x1122334455667788
                    elif manp[j][0] == "snon":  # data_2422147c8_nonce
                        manp[j][1] = b"\xfe\xed\xfa\xce" * (20 // 4)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print(
            f"{sys.argv[0]} [model] [BuildManifest.plist] [ticket.shsh2] [root_ticket.der]"
        )
        exit(1)

    model = sys.argv[1].lower()
    if model == "n104ap":
        chip_id = 0x8030
    else:
        print(f"{model} is not a known model.")
        exit(1)

    fd = open(sys.argv[2], "rb")
    manifest = plistlib.load(fd)
    fd.close()

    identity = find_build_identity(manifest, model)

    if identity is None:
        print(f"{model} is not in the build manifest plist.")
        exit(1)

    fd = open(sys.argv[3], "rb")
    shsh = plistlib.load(fd)
    ticket = shsh["ApImg4Ticket"]
    fd.close()
    res = None
    res = decode(ticket, asn1Spec=APTicket())

    a = res[0]

    b = a["manb"][0]["payload"]
    modifying_func(identity, b, chip_id)

    c = a["cert"][0]["tbsCertificate"]["extensions"][4]["extnValue"]
    res = decode(c, asn1Spec=Set())[0]
    modifying_func(identity, res, chip_id, False)
    a["cert"][0]["tbsCertificate"]["extensions"][4]["extnValue"] = encode(res)
    fd = open(sys.argv[4], "wb")

    fd.write(encode(a))
    fd.close()
PYEOF_SEP
fi
# ---------- 8. Forged tickets + SEP firmware repack ----------
DEX 'set -e; cd /work/data; T=$(find /work/src/tools -name ticket.shsh2 | head -1)
PY=/work/src/tools/bootstrap_scripts
[ -f root_ticket.der ] || python3 $PY/create_apticket.py n104ap /work/ipsw-x/BuildManifest.plist "$T" root_ticket.der
[ -f sep_root_ticket.der ] || python3 $PY/create_septicket.py n104ap /work/ipsw-x/BuildManifest.plist "$T" sep_root_ticket.der
[ "$(stat -c%s root_ticket.der)" = 8931 ] || { echo "root_ticket.der size mismatch"; exit 1; }
IMG4=/work/src/img4lib/img4
VER=$(curl -s https://wiki.nixos.org/wiki/IOS_Emulation | grep -oE "ff86cbb5[0-9a-f]+" | awk "{print length, \$0}" | sort -rn | head -1 | cut -d" " -f2)
[ -n "$VER" ] || { echo "could not fetch SEP version template from the NixOS wiki"; exit 1; }
$IMG4 -i /work/ipsw-x/Firmware/all_flash/sep-firmware.n104.RELEASE.im4p -o sep-firmware.raw -k "$(cat /work/sepkey.txt)"
$IMG4 -A -F -o sep-firmware.n104.RELEASE.new.img4 -i sep-firmware.raw -M sep_root_ticket.der -T rsep -V "$VER"
[ "$(stat -c%s sep-firmware.n104.RELEASE.new.img4)" = 7792618 ] || { echo "SEP img4 size mismatch — wrong key or version template"; exit 1; }' \
  || die "ticket/SEP stage failed (check the SEP key first)"

# ---------- 9. Empty state disks (sizes = the proven set) + companion VM ----------
DEX 'set -e; cd /work/data; Q=/work/src/Inferno/build/qemu-img
[ -f root ] || $Q create -f raw root 32G
for s in "firmware 8M" "syscfg 128K" "ctrl_bits 8K" "nvram 8K" "effaceable 4K" "panic_log 1M" "sep_nvram 64K" "sep_ssc 128K"; do
  set -- $s; [ -f "$1" ] || $Q create -f raw "$1" "$2"; done
cd /work/companion
[ -f debian.qcow2 ] || { curl -L -o debian.qcow2 https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 && $Q resize debian.qcow2 20G; }' \
  || die "disk/companion-image stage failed"
PUBKEY="$(cat "$W/keys/id_ed25519.pub")"
cat > "$W/companion/user-data" <<EOF
#cloud-config
users:
  - name: inferno
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
ssh_pwauth: true
packages:
  - openssh-server
  - usbmuxd
  - build-essential
  - autoconf
  - automake
  - libtool
  - pkg-config
  - git
  - libplist-dev
  - libssl-dev
  - libcurl4-openssl-dev
  - libzip-dev
  - libreadline-dev
  - python3
  - ca-certificates
runcmd:
  - [ systemctl, enable, --now, ssh ]
EOF
printf 'instance-id: inferno-companion-01\nlocal-hostname: inferno-companion\n' > "$W/companion/meta-data"
DEX 'set -e; cd /work/companion; [ -f seed.iso ] || genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data' \
  || die "seed ISO failed"
SSH="ssh -i /work/keys/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o ConnectTimeout=5 inferno@127.0.0.1"
SCP="scp -i /work/keys/id_ed25519 -P 2222 -o StrictHostKeyChecking=no"

# ---------- 10. Boot companion, build the libimobiledevice chain inside it ----------
DEX 'mkdir -p /work/run
[ -f /work/run/companion.pid ] && kill "$(cat /work/run/companion.pid)" 2>/dev/null; sleep 1
QB=/work/src/Inferno/build
nice -n 15 $QB/qemu-system-x86_64 -M pc -accel tcg,thread=multi -smp 1 -m 2G \
  -drive file=/work/companion/debian.qcow2,format=qcow2,if=virtio \
  -cdrom /work/companion/seed.iso \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -device usb-ehci -device usb-tcp-remote,conn-type=ipv4,conn-addr=0.0.0.0,conn-port=8030 \
  -display none -serial file:/work/logs/companion-serial.log \
  -pidfile /work/run/companion.pid -daemonize' || die "companion boot failed"
say "Waiting for companion SSH (first boot installs packages; can take 10+ min)"
DEX 'for i in $(seq 1 120); do '"$SSH"' "echo OK" 2>/dev/null | grep -q OK && exit 0; [ $((i % 6)) = 0 ] && tail -1 /work/logs/companion-serial.log 2>/dev/null; sleep 10; done; exit 1' \
  || die "companion SSH never came up (see logs/companion-serial.log)"
DEX 'set -e
'"$SSH"' "rm -rf ~/libimobiledevice-src" 2>/dev/null || true
'"$SCP"' -r /work/src/limd inferno@127.0.0.1:libimobiledevice-src
'"$SSH"' "sed -i '\''s/plist_from_memory(plist_buf, plist_len, &manifest)/plist_from_memory(plist_buf, plist_len, \&manifest, NULL)/'\'' ~/libimobiledevice-src/idevicerestore/src/ipsw.c"
'"$SSH"' "sed -i '\''s/irecv_init();/(void)0;/'\'' ~/libimobiledevice-src/idevicerestore/src/dfu.c"
'"$SSH"' "set -e; sudo apt-get update -qq > ~/apt.log 2>&1 && sudo apt-get install -y -qq libusb-1.0-0-dev libudev-dev >> ~/apt.log 2>&1 || { echo APT_FAIL; tail -20 ~/apt.log; exit 1; }
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig
rm -f ~/chain-done-idevicerestore
for p in libplist libimobiledevice-glue libtatsu libusbmuxd libimobiledevice libirecovery; do ls /usr/local/lib/pkgconfig/ 2>/dev/null | grep -q \$p && touch ~/chain-done-\$p; done
[ -x /usr/local/sbin/usbmuxd ] || [ -x /usr/local/bin/usbmuxd ] && touch ~/chain-done-usbmuxd
for p in libplist libimobiledevice-glue libtatsu libusbmuxd libimobiledevice usbmuxd libirecovery idevicerestore; do
  [ -f ~/chain-done-\$p ] && continue
  cd ~/libimobiledevice-src/\$p && ./autogen.sh --prefix=/usr/local > ~/build-\$p.log 2>&1 &&
  make -j2 >> ~/build-\$p.log 2>&1 && sudo make install >> ~/build-\$p.log 2>&1 && sudo ldconfig && touch ~/chain-done-\$p || { echo CHAIN_FAIL \$p; tail -40 ~/build-\$p.log; exit 1; }
done; sudo systemctl restart usbmuxd || true; idevicerestore --version | head -1"' \
  || die "libimobiledevice chain build failed inside companion"
DEX "$SCP /work/ipsw.ipsw /work/data/root_ticket.der inferno@127.0.0.1:" || die "file copy into companion failed"

# ---------- 11. Two-VM restore (companion USB first, then the t8030 guest) ----------
RESTORE_DONE=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
if [ "$attempt" -gt 1 ]; then
say "Restore attempt $attempt of 10 — 2-minute cool-down first (lets the host CPU recover), then relaunching the guest"
sleep 120
fi
DEX "$SSH 'pgrep -f \"idevicerestor[e]\" >/dev/null || pgrep -f \"fire-restor[e]\" >/dev/null'" || DEX "$SSH 'cat > ~/fire-restore.sh <<EOS
#!/bin/bash
for i in \$(seq 1 300); do idevice_id -l 2>/dev/null | grep -q 00008030 && break; sleep 2; done
sleep 5
idevicerestore --erase --restore-mode -i 0x1122334455667788 ~/ipsw.ipsw -T ~/root_ticket.der > ~/restore.log 2>&1
echo \$? > ~/RESTORE_EXIT
EOS
chmod +x ~/fire-restore.sh; rm -f ~/RESTORE_EXIT ~/restore.log
setsid nohup ~/fire-restore.sh > ~/fire.log 2>&1 < /dev/null & echo TRIGGER_ARMED'" || die "restore trigger failed"
DEX 'QB=/work/src/Inferno/build; D=/work/data
$QB/qemu-system-aarch64 -accel tcg,thread=multi \
  -M t8030,trustcache=$D/Restore/Firmware/038-44135-124.dmg.trustcache,ticket=$D/root_ticket.der,sep-fw=$D/sep-firmware.n104.RELEASE.new.img4,sep-rom=$D/AppleSEPROM-Cebu-B1,kaslr-off=true,usb=true,usb-conn-type=ipv4,usb-conn-addr=127.0.0.1,usb-conn-port=8030 \
  -kernel $D/Restore/kernelcache.research.iphone12b \
  -dtb $D/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p \
  -initrd $D/Restore/038-44135-124.dmg \
  -append "debug=0x14e serial=3 wdt=-1" -smp 2 -m 2G \
  -serial file:/work/logs/iphone-serial.log -display none \
  -qmp unix:/tmp/qmp.sock,server,nowait -pidfile /work/run/guest.pid -daemonize \
  -drive file=$D/sep_nvram,if=pflash,format=raw -drive file=$D/sep_ssc,if=pflash,format=raw \
  -drive file=$D/root,format=raw,if=none,id=root -device nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/firmware,format=raw,if=none,id=firmware -device nvme-ns,drive=firmware,bus=nvme-bus.0,nsid=2,nstype=2,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/syscfg,format=raw,if=none,id=syscfg -device nvme-ns,drive=syscfg,bus=nvme-bus.0,nsid=3,nstype=3,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/ctrl_bits,format=raw,if=none,id=ctrl_bits -device nvme-ns,drive=ctrl_bits,bus=nvme-bus.0,nsid=4,nstype=4,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/effaceable,format=raw,if=none,id=effaceable -device nvme-ns,drive=effaceable,bus=nvme-bus.0,nsid=6,nstype=6,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/panic_log,format=raw,if=none,id=panic_log -device nvme-ns,drive=panic_log,bus=nvme-bus.0,nsid=7,nstype=8,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/nvram,if=none,format=raw,id=nvram -device apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,logical_block_size=4096,physical_block_size=4096' \
  || die "guest boot failed"
DEX 'renice -5 -p "$(cat /work/run/guest.pid)" >/dev/null 2>&1 || true' || true
say "Restore attempt $attempt: watching the guest boot first (watchdog check), then the restore itself"
DEX 'for i in $(seq 1 36); do
  '"$SSH"' "test -f ~/RESTORE_EXIT" 2>/dev/null && exit 0
  grep -aq "waiting for host" /work/logs/iphone-serial.log 2>/dev/null && exit 0
  grep -aq "ASR RESTORE PROGRESS" /work/logs/iphone-serial.log 2>/dev/null && exit 0
  grep -aq "wdog panic" /work/logs/iphone-serial.log 2>/dev/null && { cp /work/logs/iphone-serial.log /work/logs/panic-attempt-'"$attempt"'.log 2>/dev/null; exit 2; }
  sleep 10; done; exit 0'
BW=$?
if [ $BW -eq 2 ]; then
  say "Guest watchdog-panicked on attempt $attempt — killing it and retrying the boot (serial log saved as logs/panic-attempt-$attempt.log)"
  DEX 'sleep 2; [ -f /work/run/guest.pid ] && kill "$(cat /work/run/guest.pid)" 2>/dev/null; sleep 3; echo guest stopped' || true
  continue
fi
say "Restore running (this is the slow part — progress: tail of guest serial log every minute)"
DEX 'LAST=-1; STALE=0
for i in $(seq 1 240); do
  E=$('"$SSH"' "cat ~/RESTORE_EXIT 2>/dev/null" 2>/dev/null || true)
  [ -n "$E" ] && { echo "idevicerestore exit: $E"; [ "$E" = 0 ] && exit 0 || exit 1; }
  tail -3 /work/logs/iphone-serial.log 2>/dev/null | grep -q "wdog panic" && { echo "guest watchdog-panicked mid-restore"; cp /work/logs/iphone-serial.log /work/logs/panic-attempt-'"$attempt"'.log 2>/dev/null; exit 2; }
  SZ=$(stat -c%s /work/logs/iphone-serial.log 2>/dev/null || echo 0)
  if [ "$SZ" = "$LAST" ]; then STALE=$((STALE+1)); else STALE=0; LAST=$SZ; fi
  [ "$STALE" -ge 10 ] && { echo "guest serial silent for 10 minutes"; exit 2; }
  tail -1 /work/logs/iphone-serial.log 2>/dev/null; sleep 60; done; exit 1'
RC=$?
if [ $RC -eq 0 ]; then RESTORE_DONE=1; break; fi
if [ $RC -eq 2 ]; then
  say "Guest died during restore attempt $attempt — killing it and retrying from a fresh boot"
  DEX 'sleep 2; [ -f /work/run/guest.pid ] && kill "$(cat /work/run/guest.pid)" 2>/dev/null; sleep 3; echo guest stopped' || true
  continue
fi
die "restore did not complete (see companion ~/restore.log and logs/iphone-serial.log)"
done
[ "$RESTORE_DONE" = 1 ] || die "restore did not complete after 10 guest attempts — the guest kept watchdog-panicking (this emulator's known flaky failure). Running this script again resumes at the restore and tries again."
DEX 'sleep 30; [ -f /work/run/guest.pid ] && kill "$(cat /work/run/guest.pid)" 2>/dev/null; sleep 3; echo guest stopped' || true

# ---------- 12. macOS-native APFS patches + jailbreak bootstrap ----------
say "Filesystem patches (macOS). A 'Data can't be unlocked' popup is EXPECTED — dismiss it."
cd "$DATA" || die "cd data"
hdiutil attach -imagekey diskimage-class=CRawDiskImage -blocksize 4096 -noverify -noautofsck root >/dev/null \
  || die "hdiutil attach failed"
until [ -d /Volumes/System ]; do echo "waiting for /Volumes/System (dismiss the Data popup)…"; sleep 5; done
sudo diskutil enableownership /Volumes/System || die "enableownership failed"
sudo mount -urw /Volumes/System || die "remount rw failed"
if [ ! -x "$W/fspatcher/build/inferno_fs_patcher" ]; then
  [ -d "$W/fspatcher" ] || git clone https://git.chefkiss.dev/AppleHax/InfernoFSPatcher "$W/fspatcher" \
    || die "InfernoFSPatcher clone failed (git.chefkiss.dev unreachable from this Mac?)"
  if ! command -v cmake >/dev/null 2>&1; then
    curl -L -o "$W/cmake.tar.gz" "https://cmake.org/files/v4.1/cmake-4.1.2-macos-universal.tar.gz" \
      && mkdir -p "$W/tools" && tar xf "$W/cmake.tar.gz" -C "$W/tools" \
      && export PATH="$W/tools/CMake.app/Contents/bin:$PATH" || echo "cmake download failed — trying direct clang++ build"
  fi
  if command -v cmake >/dev/null 2>&1; then
    cmake -S "$W/fspatcher" -B "$W/fspatcher/build" -DCMAKE_BUILD_TYPE=Release >/dev/null \
      && cmake --build "$W/fspatcher/build" || die "FSPatcher build failed"
  else
    mkdir -p "$W/fspatcher/build" && clang++ -std=c++17 -O2 -o "$W/fspatcher/build/inferno_fs_patcher" \
      "$W/fspatcher"/*.cpp "$W/fspatcher"/src/*.cpp 2>/dev/null || die "FSPatcher build failed (both routes)"
  fi
fi
DSC="/Volumes/System/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
[ -f "$DSC" ] || die "dyld shared cache not found on mounted System volume"
sudo "$W/fspatcher/build/inferno_fs_patcher" "$DSC" || die "dyld cache patch failed"
LP="/Volumes/System/System/Library/xpc/launchd.plist"
sudo cp "$LP" "$DATA/launchd.plist.bak"
sudo plutil -convert xml1 "$LP" || die "launchd.plist convert failed"
sudo python3 - "$LP" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f: d = plistlib.load(f)
daemons = d.setdefault('LaunchDaemons', {})
for name in ('com.apple.voicemail.vmd', 'com.apple.CommCenter', 'com.apple.CommCenterMobileHelper',
             'com.apple.CommCenterRootHelper', 'com.apple.locationd'):
    for k in list(daemons):
        if k.endswith(name + '.plist'):
            daemons[k]['Disabled'] = True
daemons['/System/Library/LaunchDaemons/bash.plist'] = {
    'EnablePressuredExit': False, 'Label': 'com.apple.bash', 'POSIXSpawnType': 'Interactive',
    'ProgramArguments': ['/bin/bash'], 'RunAtLoad': True,
    'StandardErrorPath': '/dev/console', 'StandardInPath': '/dev/console',
    'StandardOutPath': '/dev/console', 'Umask': 0, 'UserName': 'root'}
with open(p, 'wb') as f: plistlib.dump(d, f, fmt=plistlib.FMT_XML)
print('launchd.plist patched')
PYEOF
[ $? = 0 ] || die "launchd.plist patch failed"
STRAP_URL="$(python3 -c 'import json,urllib.request;print(json.load(urllib.request.urlopen("https://assets.checkra.in/loader/config.json"))["core_bootstrap_tar"])')" \
  || die "could not read checkra1n loader config"
curl -L -o "$W/strap.tar.lzma" "$STRAP_URL" || die "strap download failed"
sudo tar xf "$W/strap.tar.lzma" -C /Volumes/System || die "strap extract failed"
sudo diskutil eject /Volumes/System || hdiutil detach /Volumes/System || true

# ---------- 13. Migration boot (patched FS), then clean QMP shutdown ----------
say "Booting guest so data migration completes (serial log watched for SpringBoard)"
DEX 'QB=/work/src/Inferno/build; D=/work/data; rm -f /work/logs/iphone-serial2.log
$QB/qemu-system-aarch64 -accel tcg,thread=multi \
  -M t8030,trustcache=$D/Restore/Firmware/038-44135-124.dmg.trustcache,ticket=$D/root_ticket.der,sep-fw=$D/sep-firmware.n104.RELEASE.new.img4,sep-rom=$D/AppleSEPROM-Cebu-B1,kaslr-off=true,usb=true,usb-conn-type=ipv4,usb-conn-addr=127.0.0.1,usb-conn-port=8030 \
  -kernel $D/Restore/kernelcache.research.iphone12b \
  -dtb $D/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p \
  -append "tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 launchd_unsecure_cache=1 wdt=-1 -vm_compressor_wk_sw" \
  -smp 2 -m 2G -serial file:/work/logs/iphone-serial2.log -display none \
  -qmp unix:/tmp/qmp.sock,server,nowait -pidfile /work/run/guest.pid -daemonize \
  -drive file=$D/sep_nvram,if=pflash,format=raw -drive file=$D/sep_ssc,if=pflash,format=raw \
  -drive file=$D/root,format=raw,if=none,id=root -device nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/firmware,format=raw,if=none,id=firmware -device nvme-ns,drive=firmware,bus=nvme-bus.0,nsid=2,nstype=2,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/syscfg,format=raw,if=none,id=syscfg -device nvme-ns,drive=syscfg,bus=nvme-bus.0,nsid=3,nstype=3,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/ctrl_bits,format=raw,if=none,id=ctrl_bits -device nvme-ns,drive=ctrl_bits,bus=nvme-bus.0,nsid=4,nstype=4,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/effaceable,format=raw,if=none,id=effaceable -device nvme-ns,drive=effaceable,bus=nvme-bus.0,nsid=6,nstype=6,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/panic_log,format=raw,if=none,id=panic_log -device nvme-ns,drive=panic_log,bus=nvme-bus.0,nsid=7,nstype=8,logical_block_size=4096,physical_block_size=4096 \
  -drive file=$D/nvram,if=none,format=raw,id=nvram -device apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,logical_block_size=4096,physical_block_size=4096
for i in $(seq 1 60); do grep -q SpringBoard /work/logs/iphone-serial2.log 2>/dev/null && break; sleep 60; done
python3 - <<PYEOF
import socket
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/qmp.sock"); s.recv(4096)
s.sendall(b"{\"execute\":\"qmp_capabilities\"}\n"); s.recv(4096)
s.sendall(b"{\"execute\":\"quit\"}\n"); s.close(); print("QMP quit sent")
PYEOF
sleep 5; [ -f /work/run/companion.pid ] && kill "$(cat /work/run/companion.pid)" 2>/dev/null || true' || die "migration boot stage failed"

# ---------- 14. Assemble the EXACT app layout, verify, zip ----------
DEX 'set -e; D=/work/data; P=/work/pkg; rm -rf $P; mkdir -p $P/InfernoData/Restore/Firmware/all_flash
Q=/work/src/Inferno/build/qemu-img
$Q convert -f raw -O qcow2 -c $D/root $P/InfernoData/root.qcow2
cp $D/AppleSEPROM-Cebu-B1 $P/
for f in firmware syscfg ctrl_bits nvram effaceable panic_log sep_nvram sep_ssc root_ticket.der sep-firmware.n104.RELEASE.new.img4; do
  cp $D/$f $P/InfernoData/$f; done
cp $D/Restore/kernelcache.release.iphone12b $P/InfernoData/Restore/
cp $D/Restore/Firmware/038-44135-124.dmg.trustcache $P/InfernoData/Restore/Firmware/
cp $D/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p $P/InfernoData/Restore/Firmware/all_flash/
chk(){ [ "$(stat -c%s "$1")" = "$2" ] || { echo "VERIFY FAIL $1 want $2 got $(stat -c%s "$1")"; exit 1; }; }
chk $P/AppleSEPROM-Cebu-B1 86016
chk $P/InfernoData/firmware 8388608; chk $P/InfernoData/syscfg 131072; chk $P/InfernoData/ctrl_bits 8192
chk $P/InfernoData/nvram 8192; chk $P/InfernoData/effaceable 4096; chk $P/InfernoData/panic_log 1048576
chk $P/InfernoData/sep_nvram 65536; chk $P/InfernoData/sep_ssc 131072; chk $P/InfernoData/root_ticket.der 8931
chk $P/InfernoData/sep-firmware.n104.RELEASE.new.img4 7792618
chk $P/InfernoData/Restore/kernelcache.release.iphone12b 15704952
chk $P/InfernoData/Restore/Firmware/038-44135-124.dmg.trustcache 4931
chk $P/InfernoData/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p 42553
[ "$(stat -c%s $P/InfernoData/root.qcow2)" -gt 1000000000 ] || { echo "root.qcow2 suspiciously small"; exit 1; }
cd $P && rm -f /work/InfernoData.zip && zip -r /work/InfernoData.zip AppleSEPROM-Cebu-B1 InfernoData >/dev/null
echo "ZIP OK: $(stat -c%s /work/InfernoData.zip) bytes, sha256 $(sha256sum /work/InfernoData.zip | cut -d" " -f1)"' \
  || die "packaging/verification failed"
docker rm -f inferno1 >/dev/null 2>&1 || true
say "DONE"
echo "Your file: $W/InfernoData.zip"
echo "On the iPad: unzip it into Files -> On My iPad -> Inferno (so AppleSEPROM-Cebu-B1 and"
echo "InfernoData/ land in the app's folder), then open the app and tap 'Check again'."
printf 'Delete the 5.5 GB IPSW and extracted tree now? [y/N] '
read -r A; [ "$A" = y ] && rm -rf "$W/ipsw.ipsw" "$W/ipsw-x" && echo "IPSW deleted."
