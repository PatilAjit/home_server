#!/bin/bash
# Run as root, on the NanoPi itself, after 03-printer-setup.sh.
#
# Installs a maintenance print that exercises every ink channel on a fixed
# cadence, so an idle EcoTank's print head doesn't dry out and clog. The page
# deliberately covers solid patches, partial-density ramps and fine black text:
# nozzles clog at low duty cycles too, so solid blocks alone are not enough.
set -euo pipefail

PRINTER_NAME="${PRINTER_NAME:-Epson-ET-2850}"
INTERVAL_DAYS="${INTERVAL_DAYS:-10}"

cat > /usr/local/sbin/printer-ink-maintenance.sh << 'SCRIPT_EOF'
#!/bin/sh
# Prints an all-channel test page if enough days have passed since the last one.
set -eu

PRINTER="${PRINTER:-__PRINTER__}"
INTERVAL_DAYS="${INTERVAL_DAYS:-__INTERVAL__}"
STAMP_DIR=/var/lib/printer-ink-maintenance
STAMP="$STAMP_DIR/last-run"

mkdir -p "$STAMP_DIR"

# The timer fires daily and the elapsed check lives here rather than in the
# timer, so a reboot or downtime can't drift or skip the cadence.
now=$(date +%s)
if [ -z "${PS_OUT:-}" ]; then
	if [ -f "$STAMP" ]; then
		last=$(cat "$STAMP" 2>/dev/null || echo 0)
		elapsed_days=$(( (now - last) / 86400 ))
		if [ "$elapsed_days" -lt "$INTERVAL_DAYS" ]; then
			echo "last maintenance print was ${elapsed_days}d ago (<${INTERVAL_DAYS}d), skipping"
			exit 0
		fi
	fi

	if ! lpstat -p "$PRINTER" >/dev/null 2>&1; then
		echo "printer $PRINTER not found, skipping" >&2
		exit 1
	fi

	# Don't pile up pages when the printer is offline, jammed or out of paper -
	# otherwise every run adds another job and they all spool out at once later.
	if lpstat -o "$PRINTER" 2>/dev/null | grep -q .; then
		echo "jobs already queued on $PRINTER, skipping this cycle"
		exit 0
	fi
fi

# PS_OUT writes the page out and prints nothing - lets the layout be previewed
# (e.g. rendered with ghostscript) without burning paper or ink.
if [ -n "${PS_OUT:-}" ]; then
	PS_FILE="$PS_OUT"
else
	PS_FILE=$(mktemp /tmp/ink-maintenance-XXXXXX.ps)
	trap 'rm -f "$PS_FILE"' EXIT
fi

STAMP_TEXT="$(date '+%Y-%m-%d %H:%M %Z')"

cat > "$PS_FILE" << PS_EOF
%!PS-Adobe-3.0
%%Pages: 1
%%EndComments
/mm { 2.834645 mul } bind def

% x y c m y k -> filled 35x18mm patch
/box {
	setcmykcolor
	moveto
	0 18 mm rlineto 35 mm 0 rlineto 0 -18 mm rlineto closepath fill
} bind def

% x y c m y k -> 20-step density ramp, exercising partial nozzle duty
/ramp {
	/kk exch def /yy exch def /mm2 exch def /cc exch def
	/y0 exch def /x0 exch def
	0 1 19 {
		/i exch def
		/t i 1 add 20 div def
		cc t mul mm2 t mul yy t mul kk t mul setcmykcolor
		x0 i 8 mm mul add y0 moveto
		0 10 mm rlineto 8 mm 0 rlineto 0 -10 mm rlineto closepath fill
	} for
} bind def

0 0 0 1 setcmykcolor
/Helvetica-Bold findfont 16 scalefont setfont
20 mm 275 mm moveto (Ink maintenance page) show
/Helvetica findfont 9 scalefont setfont
20 mm 268 mm moveto (Printed $STAMP_TEXT - automatic, every $INTERVAL_DAYS days) show
20 mm 263 mm moveto (Keeps all four channels flowing so the print head does not clog while idle.) show

% --- solid patches: the four inks, then the secondary blends ---
/Helvetica-Bold findfont 10 scalefont setfont
0 0 0 1 setcmykcolor
20 mm 250 mm moveto (Solid: cyan / magenta / yellow / black) show

20 mm 228 mm 1 0 0 0 box
60 mm 228 mm 0 1 0 0 box
100 mm 228 mm 0 0 1 0 box
140 mm 228 mm 0 0 0 1 box

0 0 0 1 setcmykcolor
20 mm 218 mm moveto (Blends: red / green / blue / composite grey) show

20 mm 196 mm 0 1 1 0 box
60 mm 196 mm 1 0 1 0 box
100 mm 196 mm 1 1 0 0 box
140 mm 196 mm 0.5 0.4 0.4 0 box

% --- density ramps: clogs show up at low duty cycles first ---
0 0 0 1 setcmykcolor
20 mm 186 mm moveto (Density ramps - faint steps reveal partial nozzle blockage) show

20 mm 172 mm 1 0 0 0 ramp
20 mm 158 mm 0 1 0 0 ramp
20 mm 144 mm 0 0 1 0 ramp
20 mm 130 mm 0 0 0 1 ramp

% --- fine detail in black: exercises small droplets, not just flood fill ---
0 0 0 1 setcmykcolor
20 mm 118 mm moveto (Black text detail) show
/Helvetica findfont 8 scalefont setfont
20 mm 111 mm moveto (The quick brown fox jumps over the lazy dog. 0123456789 - 8pt) show
/Helvetica findfont 7 scalefont setfont
20 mm 105 mm moveto (The quick brown fox jumps over the lazy dog. 0123456789 - 7pt) show
/Helvetica findfont 6 scalefont setfont
20 mm 99 mm moveto (The quick brown fox jumps over the lazy dog. 0123456789 - 6pt) show

% --- hairlines in each ink: thin strokes clog soonest ---
0.4 setlinewidth
0 1 11 {
	/i exch def
	i 4 mod 0 eq { 1 0 0 0 setcmykcolor } if
	i 4 mod 1 eq { 0 1 0 0 setcmykcolor } if
	i 4 mod 2 eq { 0 0 1 0 setcmykcolor } if
	i 4 mod 3 eq { 0 0 0 1 setcmykcolor } if
	20 mm 88 mm i 2 mm mul sub moveto
	170 mm 88 mm i 2 mm mul sub lineto stroke
} for

showpage
%%EOF
PS_EOF

if [ -n "${PS_OUT:-}" ]; then
	echo "wrote $PS_OUT (preview only, nothing printed)"
	exit 0
fi

if lp -d "$PRINTER" -t "ink-maintenance" "$PS_FILE" >/dev/null 2>&1; then
	echo "$now" > "$STAMP"
	echo "maintenance page submitted to $PRINTER"
else
	echo "failed to submit maintenance page to $PRINTER" >&2
	exit 1
fi
SCRIPT_EOF

sed -i "s|__PRINTER__|$PRINTER_NAME|; s|__INTERVAL__|$INTERVAL_DAYS|" \
	/usr/local/sbin/printer-ink-maintenance.sh
chmod +x /usr/local/sbin/printer-ink-maintenance.sh

cat > /etc/systemd/system/printer-ink-maintenance.service << 'EOF'
[Unit]
Description=Print an all-channel page to keep the inkjet head from clogging
After=cups.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/printer-ink-maintenance.sh
EOF

# Fires daily; the script itself enforces the real interval. Persistent=true so
# a run missed while the box was off happens shortly after it comes back -
# which matters, since the whole point is not leaving the head idle too long.
cat > /etc/systemd/system/printer-ink-maintenance.timer << 'EOF'
[Unit]
Description=Daily check whether an ink maintenance page is due
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now printer-ink-maintenance.timer

echo
echo "Installed. Cadence: every $INTERVAL_DAYS days on $PRINTER_NAME."
echo "  print one now:  /usr/local/sbin/printer-ink-maintenance.sh"
echo "  force a print:  rm /var/lib/printer-ink-maintenance/last-run && /usr/local/sbin/printer-ink-maintenance.sh"
echo "  next run:       systemctl list-timers printer-ink-maintenance.timer"
echo "  history:        journalctl -u printer-ink-maintenance.service"
systemctl list-timers printer-ink-maintenance.timer --no-pager
