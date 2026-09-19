#!/bin/bash
# One-time host setup for the webcam feature: a v4l2loopback device that
# Meet, Teams, Zoom, OBS… list as an ordinary camera. The plugin runs this in
# a floating terminal; it is the only place the feature needs sudo.
#
#   1. install v4l2loopback-dkms and the running kernel's headers (DKMS builds
#      the module against them, and rebuilds on every kernel update)
#   2. drop a modprobe.d + modules-load.d pair so the device exists at boot
#      with a fixed number and a friendly label
#   3. load the module now
#
# Usage: setup-webcam.sh [/dev/videoN]   (label is fixed: the panel matches on it)
set -euo pipefail

dev=${1:-/dev/video42}
label="Android Mirror Camera"
nr=${dev#/dev/video}
case "$nr" in ''|*[!0-9]*) echo "Device must look like /dev/video42, got: $dev" >&2; exit 2 ;; esac

kernel=$(uname -r)
pkgbase=/usr/lib/modules/$kernel/pkgbase
if [ ! -r "$pkgbase" ]; then
  echo "Cannot tell which package provides kernel $kernel (no $pkgbase)." >&2
  echo "Install its headers by hand, then run this again." >&2
  exit 1
fi
headers="$(<"$pkgbase")-headers"

echo "Installing v4l2loopback-dkms and $headers…"
omarchy pkg add v4l2loopback-dkms "$headers"

conf_name=android-mirror-webcam.conf
echo "Registering $dev as \"$label\" (loads at boot)…"
printf 'options v4l2loopback devices=1 video_nr=%s card_label="%s" exclusive_caps=1\n' "$nr" "$label" \
  | sudo tee /etc/modprobe.d/$conf_name >/dev/null
printf 'v4l2loopback\n' | sudo tee /etc/modules-load.d/$conf_name >/dev/null

current=$(cat "/sys/class/video4linux/video$nr/name" 2>/dev/null || true)
if lsmod | grep -q '^v4l2loopback ' && [ "$current" != "$label" ]; then
  # Loaded earlier with different options (another plugin, a manual modprobe,
  # or an older version of this script). Reload so the options above apply;
  # this fails if an app currently has a loopback device open.
  echo "v4l2loopback is loaded with other options; reloading it…"
  sudo modprobe -r v4l2loopback || { echo "Close every app using a virtual camera, then run Set up again." >&2; exit 1; }
fi
sudo modprobe v4l2loopback

name=$(cat "/sys/class/video4linux/video$nr/name" 2>/dev/null || true)
if [ "$name" != "$label" ]; then
  echo "The module loaded but $dev is not \"$label\" (got: '${name:-nothing}')." >&2
  echo "If another tool owns v4l2loopback, close it and run: sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback" >&2
  exit 1
fi
echo "Done. $dev is \"$label\"; pick it as the camera in Meet, Teams or Zoom."
