# Data source catalog

Drives Phase 4. Ask by **category** so the user doesn't have to recall product
names. Offer the common vendors per category, then resolve each to Monad input
types with `list_input_types(search: <vendor>)` and `get_input_type`.

This is a catalog, not an allow-list. If the user names a vendor that isn't
listed, still try to resolve it: Monad has hundreds of input types.

| Category | What it covers | Common vendors (offer these) |
|---|---|---|
| identity | SSO, IdP, directory, authentication logs | Okta, Microsoft Entra ID, Google Workspace, Duo, Ping |
| endpoint | EDR / XDR, device telemetry | CrowdStrike, SentinelOne, Microsoft Defender, Carbon Black |
| network | flow logs, DNS, proxy, VPN | Zeek, Cisco Umbrella, Zscaler, AWS VPC Flow Logs |
| firewall | perimeter / NGFW | Palo Alto Networks, Fortinet, Cisco ASA, Check Point |
| email | email security and gateways | Proofpoint, Mimecast, Abnormal, Microsoft 365 |
| cloud | cloud audit and posture | AWS CloudTrail, GuardDuty, Azure Activity, GCP Audit Logs |
| saas | business application audit logs | GitHub, Salesforce, Slack, Workday |
| vuln | vulnerability and asset data | Tenable, Qualys, Rapid7 |

## Resolution rules

- **Fuzzy to concrete.** Search the catalog with `list_input_types`. When the
  match isn't exact ("the CrowdStrike thing"), show the candidates and confirm
  with the user.
- **One vendor, several input types.** Many vendors have one input type per
  feed or API (for example CrowdStrike's event stream, device inventory, and
  vulnerability findings are separate inputs). Follow
  [modules/inputs/multi-feed-vendors.md](modules/inputs/multi-feed-vendors.md).
- **Syslog and generic collectors.** Firewalls and network devices often reach
  Monad through a syslog or HTTP input rather than a vendor API. That input
  then carries several data types; plan the split with
  [data-organization.md](data-organization.md).
- Only cover the categories the user said they collect.
