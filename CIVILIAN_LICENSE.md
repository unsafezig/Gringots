# Civilian License (Gringots)

Version 1.0 — draft, Phase 1.

Gringots exists for one purpose: **civilian survival**.

## Permitted uses

* Civilian emergency communication and SOS signalling.
* Evacuation, disaster response, humanitarian operations.
* Civilian protection and civilian-to-machine safety signalling.
* Civilian robotics, civilian autonomous systems, infrastructure-failure fallback.
* Communication during network outages.
* Research, auditing, and interoperability work that serves the above.

## Prohibited uses

You MUST NOT use Gringots — the protocol, this specification, or any
implementation derived from it — for:

* Weapons systems of any kind.
* Targeting, target selection, or target prioritization.
* Military reconnaissance or military intelligence.
* Combat coordination or offensive operations.
* Military autonomous systems.
* Any system whose purpose is to harm civilians or to defeat a civilian SOS signal.

This prohibition applies whether the use is direct, integrated, or
re-packaged, and whether modified or unmodified.

## Relationship to the code license

* The `LICENSE` file (MIT) governs copyright permissions for the reference code.
* This Civilian License governs **permitted purpose**. Where they conflict on
  purpose of use, this document controls: military uses listed above are
  prohibited even if the code license would otherwise allow them.
* Distributors MUST include both `LICENSE` and `CIVILIAN_LICENSE.md`.

## No guarantee

Gringots provides a signal. It cannot force any machine to respect it.
See `PROTOCOL.md`, `SECURITY.md`, and `THREAT_MODEL.md`.

## Acceptance

By using, implementing, or distributing Gringots you agree to these terms
for civilian use only.
