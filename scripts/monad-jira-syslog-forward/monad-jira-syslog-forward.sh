#!/usr/bin/env bash
#
# monad-jira-syslog-forward.sh
#
# Configure rsyslog on an on-premises Linux server running Atlassian Jira
# (Server / Data Center) to forward Jira application logs to a Monad
# Syslog input pipeline.
#
# Monad Syslog input expects (see https://app.monad.com/docs/inputs/monad/monad-syslog):
#   - Endpoint:  <pipeline-id>.l4.monad.com:6514
#   - Transport: persistent TCP + TLS
#   - Routing:   SNI (primary); client certificate with
#                Subject.serialNumber=<pipeline-id>; or a registered
#                SHA-256 certificate fingerprint
#   - Framing:   RFC 6587 (octet-counted preferred)
#   - Format:    RFC 5424 (auto-detected server-side)
#
# TLS identification mode is detected automatically (--tls-mode auto):
#   1. sni          rsyslogd >= 8.31 (gtls sends SNI since 8.31.0, Nov 2017).
#   2. client-cert  Older rsyslog: generate a self-signed certificate with
#                   the pipeline UUID in Subject.serialNumber.
#   3. fingerprint  Self-signed certs not possible (an existing/mandated
#                   certificate must be used): present the existing cert
#                   (--cert/--key) and print its SHA-256 fingerprint with
#                   instructions to register it on the pipeline's Syslog
#                   input (Monad UI, or via Monad Customer Support).
#
# Usage:
#   sudo ./monad-jira-syslog-forward.sh -p <pipeline-uuid> [options]
#
# Run with --help for the full option reference, TLS mode details, and
# worked examples (the help text below in usage() is the single source
# of truth for arguments).
#
set -euo pipefail

PIPELINE_ID=""
JIRA_HOME="/var/atlassian/application-data/jira"
JIRA_INSTALL=""
TLS_MODE="auto"
CERT_PATH=""
KEY_PATH=""
DRY_RUN=0

RSYSLOG_CONF="/etc/rsyslog.d/10-monad-jira.conf"
CERT_DIR="/etc/rsyslog.d/monad"
SNI_MIN_MINOR=31   # gtls client SNI since rsyslog 8.31.0

SCRIPT_NAME="$(basename "$0")"
UUID_GLOB="[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"

usage() {
  cat <<EOF
$SCRIPT_NAME — forward on-prem Jira logs to a Monad Syslog input
pipeline over TLS (rsyslog imfile -> <pipeline-id>.l4.monad.com:6514).

USAGE
  sudo ./$SCRIPT_NAME -p <pipeline-uuid> [options]

REQUIRED
  -p <uuid>          Monad pipeline ID: the UUID of the pipeline that has the
                     Syslog input. Find it in the pipeline page URL in the
                     Monad UI, or via the List Pipelines API
                     (GET https://app.monad.com/api/v2/<org-id>/pipelines).

OPTIONS
  -j <dir>           JIRA_HOME (default: /var/atlassian/application-data/jira).
                     Jira logs are read from <dir>/log/.
  -i <dir>           Jira install dir; also forwards Tomcat catalina.out from
                     <dir>/logs/ (e.g. /opt/atlassian/jira). Off by default.
  --tls-mode <mode>  How Monad identifies the destination pipeline:
                       auto         detect (default; see TLS MODES below)
                       sni          TLS SNI — needs rsyslog >= 8.31
                       client-cert  generate a self-signed identification
                                    certificate (serialNumber=<pipeline-id>)
                       fingerprint  use an existing certificate (--cert/--key);
                                    prints its SHA-256 to register with Monad
  --cert <pem>       Existing PEM certificate (fingerprint mode).
  --key <pem>        Existing PEM private key (fingerprint mode).
  -n, --dry-run      Print what would be done without changing anything.
                     Works on machines without rsyslog installed.
  -h, --help         Show this help.

Long options also accept --opt=value (e.g. --tls-mode=sni).

TLS MODES (--tls-mode auto picks the first that fits)
  1. sni          rsyslogd >= 8.31 sends SNI automatically (since Nov 2017).
  2. client-cert  older rsyslog, openssl available.
  3. fingerprint  --cert/--key supplied — use when self-signed certificates
                  are not permitted (e.g. a mandated appliance certificate).

EXAMPLES
  # Typical: modern server, default Jira paths
  sudo ./$SCRIPT_NAME -p 0bffd278-fbc2-4804-ba5f-1969587c1da6

  # Preview without changing anything
  ./$SCRIPT_NAME -p 0bffd278-fbc2-4804-ba5f-1969587c1da6 --dry-run

  # CentOS 7-era rsyslog (no SNI): self-signed identification cert
  sudo ./$SCRIPT_NAME -p 0bffd278-fbc2-4804-ba5f-1969587c1da6 --tls-mode client-cert

  # Mandated appliance cert: prints its SHA-256 fingerprint to register
  # on the pipeline's Syslog input (Monad UI, or via Monad Customer Support)
  sudo ./$SCRIPT_NAME -p 0bffd278-fbc2-4804-ba5f-1969587c1da6 \\
    --tls-mode fingerprint --cert /etc/pki/jira.crt --key /etc/pki/jira.key
EOF
  exit "${1:-0}"
}

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Argument errors: explain the problem, then point at --help.
err_help() { printf 'ERROR: %s\n\nRun ./%s --help for usage and examples.\n' "$1" "$SCRIPT_NAME" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# Reject a missing value, or one that is actually the next option ("-p -n").
need_value() {
  if [ -z "${2:-}" ]; then
    err_help "option $1 requires a value (none given)"
  fi
  case "$2" in
    -*) err_help "option $1 requires a value, but got what looks like another option: '$2'" ;;
  esac
}

is_uuid() { case "$1" in $UUID_GLOB) return 0 ;; *) return 1 ;; esac; }

[ $# -gt 0 ] || usage 1 >&2

while [ $# -gt 0 ]; do
  case "$1" in
    -p) need_value "-p" "${2:-}"; PIPELINE_ID="$2"; shift 2 ;;
    -j) need_value "-j" "${2:-}"; JIRA_HOME="$2"; shift 2 ;;
    -i) need_value "-i" "${2:-}"; JIRA_INSTALL="$2"; shift 2 ;;
    --tls-mode) need_value "--tls-mode" "${2:-}"; TLS_MODE="$2"; shift 2 ;;
    --tls-mode=*) TLS_MODE="${1#*=}"; shift ;;
    --client-cert) TLS_MODE="client-cert"; shift ;;   # back-compat alias
    --cert) need_value "--cert" "${2:-}"; CERT_PATH="$2"; shift 2 ;;
    --cert=*) CERT_PATH="${1#*=}"; shift ;;
    --key) need_value "--key" "${2:-}"; KEY_PATH="$2"; shift 2 ;;
    --key=*) KEY_PATH="${1#*=}"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    -*) err_help "unknown option: $1" ;;
    *) err_help "unexpected argument: '$1' — every parameter is passed as an option (did you mean -p $1?)" ;;
  esac
done

# --- 1. Argument validation ----------------------------------------------------

if [ -z "$PIPELINE_ID" ]; then
  err_help "the pipeline ID is required: -p <uuid> identifies the Monad pipeline that receives the logs"
fi

# Monad routes by the pipeline UUID embedded in the hostname; a malformed ID
# fails silently at the TLS layer, so validate the shape up front.
# Uppercase is safe to fix automatically — Monad expects lowercase.
LOWERED="$(printf '%s' "$PIPELINE_ID" | tr '[:upper:]' '[:lower:]')"
if [ "$LOWERED" != "$PIPELINE_ID" ]; then
  info "note: pipeline ID lowercased to $LOWERED (Monad expects lowercase UUIDs)"
  PIPELINE_ID="$LOWERED"
fi
if ! is_uuid "$PIPELINE_ID"; then
  err_help "-p must be a pipeline UUID (8-4-4-4-12 hex digits, e.g.
0bffd278-fbc2-4804-ba5f-1969587c1da6), got: '$PIPELINE_ID'
Find the pipeline ID in the pipeline page URL in the Monad UI, or via
GET https://app.monad.com/api/v2/<org-id>/pipelines. An organization ID,
pipeline NAME, or input ID will not work here."
fi

case "$TLS_MODE" in
  auto|sni|client-cert|fingerprint) ;;
  *) err_help "--tls-mode '$TLS_MODE' is not valid — choose one of: auto, sni, client-cert, fingerprint (see TLS MODES in --help)" ;;
esac

# --cert and --key only work as a pair: the certificate is presented to Monad
# and the key proves possession; rsyslog needs both.
if [ -n "$CERT_PATH" ] && [ -z "$KEY_PATH" ]; then
  err_help "--cert was given without --key — rsyslog needs the private key to present the certificate"
fi
if [ -n "$KEY_PATH" ] && [ -z "$CERT_PATH" ]; then
  err_help "--key was given without --cert — pass the matching certificate too"
fi
if [ "$TLS_MODE" = "fingerprint" ] && { [ -z "$CERT_PATH" ] || [ -z "$KEY_PATH" ]; }; then
  err_help "--tls-mode fingerprint uses an EXISTING certificate: pass it with --cert <pem> --key <pem>
(if you don't have one and self-signed certs are allowed, use --tls-mode client-cert instead)"
fi
if [ "$TLS_MODE" = "sni" ] || [ "$TLS_MODE" = "client-cert" ]; then
  [ -z "$CERT_PATH" ] || info "note: --cert/--key are ignored in $TLS_MODE mode (only fingerprint mode uses an existing certificate)"
fi
if [ -n "$CERT_PATH" ]; then
  [ -r "$CERT_PATH" ] || err_help "--cert: certificate not found or not readable: $CERT_PATH"
  [ -r "$KEY_PATH" ] || err_help "--key: private key not found or not readable: $KEY_PATH"
fi

# --- 2. Preflight ----------------------------------------------------------------

TARGET_HOST="${PIPELINE_ID}.l4.monad.com"
TARGET_PORT="6514"

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  err "must run as root (writes $RSYSLOG_CONF and restarts rsyslog); or use --dry-run"
fi

JIRA_LOG_DIR="$JIRA_HOME/log"
if [ ! -d "$JIRA_LOG_DIR" ]; then
  err "Jira log directory not found: $JIRA_LOG_DIR (set JIRA_HOME with -j)"
fi
if ! ls "$JIRA_LOG_DIR"/atlassian-jira*.log >/dev/null 2>&1; then
  err "no atlassian-jira*.log files in $JIRA_LOG_DIR — is this the right JIRA_HOME?"
fi

if [ -n "$JIRA_INSTALL" ] && [ ! -f "$JIRA_INSTALL/logs/catalina.out" ]; then
  err "catalina.out not found at $JIRA_INSTALL/logs/catalina.out (check -i)"
fi

if ! command -v rsyslogd >/dev/null 2>&1; then
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] rsyslog not installed on this machine — config preview only"
  else
    err "rsyslog is not installed"
  fi
fi

# The TLS stream driver ships separately on most distros, and WHICH driver is
# available varies: Debian/Ubuntu/AL2/RHEL package gnutls (gtls); Amazon Linux
# 2023 packages ONLY rsyslog-openssl (ossl). Detect what's present, install
# what's available, and remember the driver for the config and SNI decision.
STREAM_DRIVER=""

detect_stream_driver() {
  if [ -n "$(find /usr/lib /usr/lib64 -name 'lmnsd_gtls.so' -print -quit 2>/dev/null)" ]; then
    STREAM_DRIVER="gtls"
  elif [ -n "$(find /usr/lib /usr/lib64 -name 'lmnsd_ossl.so' -print -quit 2>/dev/null)" ]; then
    STREAM_DRIVER="ossl"
  else
    return 1
  fi
}

ensure_tls_driver() {
  if detect_stream_driver; then
    info "rsyslog TLS stream driver: $STREAM_DRIVER"
    return 0
  fi
  info "no rsyslog TLS driver found; installing (rsyslog-gnutls, or rsyslog-openssl as fallback)"
  if [ "$DRY_RUN" -eq 1 ]; then
    STREAM_DRIVER="gtls"
    info "[dry-run] would install the TLS driver — preview assumes gtls"
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y rsyslog-gnutls || apt-get install -y rsyslog-openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y rsyslog-gnutls || dnf install -y rsyslog-openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y rsyslog-gnutls || yum install -y rsyslog-openssl
  else
    err "could not find a package manager to install a TLS driver; install rsyslog-gnutls or rsyslog-openssl manually"
  fi
  detect_stream_driver || err "TLS driver install appeared to succeed but no lmnsd_gtls.so/lmnsd_ossl.so was found"
  info "rsyslog TLS stream driver: $STREAM_DRIVER"
}
ensure_tls_driver

# --- 3. TLS identification mode detection -------------------------------------

rsyslog_version() {
  rsyslogd -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# Client SNI requires BOTH the right driver and the right version:
#   gtls sends SNI from the target hostname since 8.31.0 (Nov 2017).
#   ossl does NOT send client SNI in any released rsyslog (checked through
#   v8.2510) — so e.g. Amazon Linux 2023 (ossl only) always needs a cert.
# Version minors are monotonic across the scheme change (… 30, 31, … 36,
# 1901, … 2312 …), so a plain numeric compare on MAJOR.MINOR is safe.
sni_supported() {
  local v maj min
  [ "$STREAM_DRIVER" = "gtls" ] || return 1
  v="$(rsyslog_version)" || return 1
  [ -n "$v" ] || return 1
  maj="${v%%.*}"
  min="${v#*.}"; min="${min%%.*}"
  [ "$maj" -gt 8 ] || { [ "$maj" -eq 8 ] && [ "$min" -ge "$SNI_MIN_MINOR" ]; }
}

no_sni_reason() {
  if [ "$STREAM_DRIVER" != "gtls" ]; then
    printf 'TLS driver is %s, which does not send client SNI in any released rsyslog' "$STREAM_DRIVER"
  else
    printf 'rsyslog %s lacks client SNI (< 8.31)' "$(rsyslog_version)"
  fi
}

if [ "$TLS_MODE" = "auto" ]; then
  if ! command -v rsyslogd >/dev/null 2>&1; then
    # dry-run preview on a machine without rsyslog
    TLS_MODE="sni"
    info "[dry-run] cannot detect rsyslog version — preview assumes tls-mode=sni"
  elif sni_supported; then
    TLS_MODE="sni"
    info "rsyslog $(rsyslog_version) with gtls supports client SNI (>= 8.31) — tls-mode=sni"
  elif [ -n "$CERT_PATH" ] || [ -n "$KEY_PATH" ]; then
    TLS_MODE="fingerprint"
    info "$(no_sni_reason); existing cert supplied — tls-mode=fingerprint"
  elif command -v openssl >/dev/null 2>&1; then
    TLS_MODE="client-cert"
    info "$(no_sni_reason) — tls-mode=client-cert"
  else
    err "$(no_sni_reason), and openssl is unavailable to
generate a client certificate. Options:
  - install openssl and re-run (client-cert mode), or
  - re-run with --tls-mode fingerprint --cert <pem> --key <pem> to use an
    existing certificate and register its SHA-256 fingerprint with Monad"
  fi
elif [ "$TLS_MODE" = "sni" ] && command -v rsyslogd >/dev/null 2>&1 && ! sni_supported; then
  err "--tls-mode sni was forced, but $(no_sni_reason).
Use --tls-mode client-cert (or fingerprint) on this server."
fi

# --- 4. Certificate setup per mode ---------------------------------------------

CERT_GLOBALS=""
FINGERPRINT=""

# Ubuntu/Debian rsyslog drops privileges (PrivDropToUser syslog) after reading
# its config but BEFORE the TLS driver opens the cert/key, so root-only key
# files fail with GnuTLS error -64. Detect the runtime user and chown to it.
rsyslog_runtime_user() {
  # always exits 0: grep returns 1 on no-match, which would trip pipefail
  { grep -rhiE '^\s*\$PrivDropToUser\s+\S+' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | awk '{print $2}' | head -1
    grep -rhoE 'privdrop\.user\.name="[^"]+"' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | sed 's/.*="\(.*\)"/\1/' | head -1
  } | head -1 || true
}

secure_cert_perms() {
  local cert="$1" key="$2" user
  chmod 644 "$cert"
  chmod 600 "$key"
  user="$(rsyslog_runtime_user)"
  if [ -n "$user" ] && id "$user" >/dev/null 2>&1; then
    info "rsyslog drops privileges to '$user' — granting it the cert/key"
    chown "$user" "$cert" "$key"
  fi
}

setup_client_cert() {
  CERT_PATH="$CERT_DIR/monad-client.crt"
  KEY_PATH="$CERT_DIR/monad-client.key"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would generate client cert with serialNumber=$PIPELINE_ID at $CERT_PATH"
    return 0
  fi
  if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
    info "client cert already present at $CERT_PATH — keeping it"
    return 0
  fi
  command -v openssl >/dev/null 2>&1 || err "openssl required for client-cert mode"
  # CN is ignored by Monad (routing uses Subject.serialNumber) but identifies
  # the cert's purpose and origin host to humans. X.509 caps CN at 64 chars.
  local cn
  cn="monad-jira-syslog-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)"
  cn="${cn:0:64}"
  info "generating client certificate (CN=$cn, serialNumber=$PIPELINE_ID)"
  mkdir -p "$CERT_DIR"
  # Pipeline UUID in Subject.serialNumber is Monad's documented non-SNI
  # identification method. RSA (not ECDSA): old gtls (rsyslog 8.24 on Amazon
  # Linux 2 / CentOS 7) cannot parse EC keys — GnuTLS -67 "ASN1 parser".
  openssl req -x509 -newkey rsa:2048 -nodes \
    -days 3650 -subj "/CN=${cn}/serialNumber=${PIPELINE_ID}" \
    -keyout "$KEY_PATH" -out "$CERT_PATH"
  secure_cert_perms "$CERT_PATH" "$KEY_PATH"
}

setup_fingerprint() {
  [ -n "$CERT_PATH" ] && [ -n "$KEY_PATH" ] || err "fingerprint mode needs --cert <pem> and --key <pem>"
  [ -r "$CERT_PATH" ] || err "certificate not readable: $CERT_PATH"
  [ -r "$KEY_PATH" ] || err "private key not readable: $KEY_PATH"
  command -v openssl >/dev/null 2>&1 || err "openssl required to compute the certificate fingerprint"

  # SHA-256 over the DER-encoded certificate — Monad's documented format
  FINGERPRINT="$(openssl x509 -in "$CERT_PATH" -outform DER | openssl dgst -sha256 -hex | grep -oE '[0-9a-f]{64}')"
  [ -n "$FINGERPRINT" ] || err "could not compute SHA-256 fingerprint of $CERT_PATH"
  info "certificate SHA-256 fingerprint: $FINGERPRINT"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would copy cert/key to $CERT_DIR and print registration instructions"
    return 0
  fi

  # Copy into rsyslog's cert dir (originals untouched) so we can set the
  # ownership the rsyslog runtime user needs without altering customer files.
  mkdir -p "$CERT_DIR"
  cp "$CERT_PATH" "$CERT_DIR/monad-existing.crt"
  cp "$KEY_PATH" "$CERT_DIR/monad-existing.key"
  CERT_PATH="$CERT_DIR/monad-existing.crt"
  KEY_PATH="$CERT_DIR/monad-existing.key"
  secure_cert_perms "$CERT_PATH" "$KEY_PATH"
  cat <<EOF

ACTION REQUIRED — register this certificate fingerprint with Monad so the
pipeline accepts data from this server. On the pipeline's Syslog input,
add it under certificate fingerprints:

  $FINGERPRINT

In the Monad UI: open the pipeline -> Syslog input -> Certificate
fingerprints. If you don't see that option, send the fingerprint to
Monad Customer Support and we will register it for you. Forwarding
starts working once the fingerprint is registered.
EOF
}

case "$TLS_MODE" in
  client-cert) setup_client_cert ;;
  fingerprint) setup_fingerprint ;;
esac

# Old gtls (e.g. rsyslog 8.24 on Amazon Linux 2 / CentOS 7) refuses to load at
# all without a CA file — "ca certificate is not set, cannot continue" — even
# in anon auth mode. Newer versions only warn. Always point it at the system
# CA bundle; harmless where optional, required where not.
system_ca_bundle() {
  local f
  for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
    if [ -r "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 0   # none found: omit the directive (pre-fix behavior)
}
CA_FILE="$(system_ca_bundle)"
[ -n "$CA_FILE" ] || info "warning: no system CA bundle found — old gtls versions may refuse to start TLS"

GLOBAL_LINES=""
[ -n "$CA_FILE" ] && GLOBAL_LINES="  DefaultNetstreamDriverCAFile=\"$CA_FILE\""
if [ "$TLS_MODE" != "sni" ]; then
  GLOBAL_LINES="${GLOBAL_LINES:+$GLOBAL_LINES
}  DefaultNetstreamDriverCertFile=\"$CERT_PATH\"
  DefaultNetstreamDriverKeyFile=\"$KEY_PATH\""
fi
CERT_GLOBALS=""
if [ -n "$GLOBAL_LINES" ]; then
  CERT_GLOBALS="global(
$GLOBAL_LINES
)"
fi

# --- 5. rsyslog configuration --------------------------------------------------

# Optional Tomcat input block
TOMCAT_INPUT=""
if [ -n "$JIRA_INSTALL" ]; then
  TOMCAT_INPUT="
# Tomcat container log (startup errors, GC notes, anything not in log4j)
input(type=\"imfile\"
      File=\"$JIRA_INSTALL/logs/catalina.out\"
      Tag=\"jira-catalina\"
      Severity=\"info\"
      Facility=\"local6\"
      PersistStateInterval=\"100\"
      ruleset=\"monad_jira\")"
fi

CONF_CONTENT="## Managed by monad-jira-syslog-forward.sh — do not edit by hand.
## Forwards Jira logs to Monad Syslog input pipeline $PIPELINE_ID
## Endpoint: $TARGET_HOST:$TARGET_PORT (TLS, RFC 5424, octet-counted framing)
## TLS identification mode: $TLS_MODE

module(load=\"imfile\")
$CERT_GLOBALS

# Jira application log (log4j). startmsg.regex joins multiline stack traces
# into single events; readTimeout flushes the final buffered event after 2s
# of quiet (without it, the last event waits for the NEXT log line).
input(type=\"imfile\"
      File=\"$JIRA_LOG_DIR/atlassian-jira.log\"
      Tag=\"jira-app\"
      Severity=\"info\"
      Facility=\"local6\"
      startmsg.regex=\"^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]\"
      readTimeout=\"2\"
      PersistStateInterval=\"100\"
      ruleset=\"monad_jira\")

# Jira security log (auth events, permission changes)
input(type=\"imfile\"
      File=\"$JIRA_LOG_DIR/atlassian-jira-security.log\"
      Tag=\"jira-security\"
      Severity=\"notice\"
      Facility=\"local6\"
      startmsg.regex=\"^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]\"
      readTimeout=\"2\"
      PersistStateInterval=\"100\"
      ruleset=\"monad_jira\")
$TOMCAT_INPUT

# Dedicated ruleset: only Jira file inputs reach Monad — local syslog
# traffic (sshd, cron, kernel) is NOT forwarded.
ruleset(name=\"monad_jira\") {
  action(type=\"omfwd\"
         target=\"$TARGET_HOST\"
         port=\"$TARGET_PORT\"
         protocol=\"tcp\"
         TCP_Framing=\"octet-counted\"
         template=\"RSYSLOG_SyslogProtocol23Format\"
         StreamDriver=\"$STREAM_DRIVER\"
         StreamDriverMode=\"1\"
         StreamDriverAuthMode=\"anon\"
         action.resumeRetryCount=\"-1\"
         queue.type=\"LinkedList\"
         queue.filename=\"monad_jira_fwd\"
         queue.maxDiskSpace=\"1g\"
         queue.saveOnShutdown=\"on\")
}
"

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] tls-mode=$TLS_MODE; would write $RSYSLOG_CONF:"
  printf '%s\n' "$CONF_CONTENT"
  info "[dry-run] would validate with: rsyslogd -N1"
  info "[dry-run] would restart rsyslog"
  exit 0
fi

info "writing $RSYSLOG_CONF (tls-mode=$TLS_MODE)"
printf '%s\n' "$CONF_CONTENT" > "$RSYSLOG_CONF"

# --- 6. Validate + restart -----------------------------------------------------

info "validating rsyslog configuration"
if ! rsyslogd -N1 >/dev/null 2>&1; then
  rsyslogd -N1 || true
  rm -f "$RSYSLOG_CONF"
  err "rsyslog config validation failed — $RSYSLOG_CONF removed, no changes applied"
fi

info "restarting rsyslog"
systemctl restart rsyslog

# --- 7. Verify -----------------------------------------------------------------

sleep 2
if ss -tn "dst :$TARGET_PORT" 2>/dev/null | grep -q ESTAB; then
  info "TLS connection to $TARGET_HOST:$TARGET_PORT is ESTABLISHED"
else
  info "no connection yet — rsyslog dials on first message. Generate one, then re-check:"
  printf '      ss -tn dst :%s\n' "$TARGET_PORT"
fi

cat <<EOF

Done. Jira logs now forward to Monad pipeline $PIPELINE_ID (tls-mode=$TLS_MODE).

Verify end to end:
  1. Trigger a Jira log line (e.g. log in to Jira, or:
       echo "\$(date '+%Y-%m-%d %H:%M:%S,000') INFO monad-forward-test" >> $JIRA_LOG_DIR/atlassian-jira.log)
  2. Check the connection:    ss -tn dst :$TARGET_PORT
  3. Check rsyslog health:    systemctl status rsyslog; journalctl -u rsyslog -n 20
  4. In Monad, sample the pipeline's input node and look for app-name
     "jira-app" / "jira-security" events.

If events do not arrive and 'journalctl -u rsyslog' shows TLS handshake
errors, re-run with --tls-mode client-cert (self-signed identification
certificate) or --tls-mode fingerprint --cert <pem> --key <pem>
(register an existing certificate's SHA-256 with Monad).
EOF
