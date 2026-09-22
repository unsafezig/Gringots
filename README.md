# Gringots

🔔 Gringots

A civilian SOS protocol for a world of autonomous machines.

Gringots is an open protocol for communicating one simple message to autonomous machines:

I am a civilian. I am not a threat.

The protocol is designed for a future where robots, drones and other autonomous systems may operate around civilians without a human continuously controlling them.

Gringots gives a civilian a recognizable way to announce themselves.

It does not attempt to identify enemies.

It identifies civilians who choose to identify themselves.

⸻

🔔 The Gringots Bell

The name comes from the bell used to calm the dragon guarding the Gringotts vaults.

The idea is simple:

Ring the bell. Let the machine know you are not a threat.

A phone or civilian device tries to communicate the same Gringots message through whatever communication channels are available.

The protocol is transport-independent.

Possible transports include:

* Bluetooth LE
* Wi-Fi
* Wi-Fi Direct
* local mesh
* LoRa
* Zinux networking
* future radio technologies
* audio

The message stays the same.

Only the transport changes.

⸻

One Message, Many Ways

Gringots does not assume that a civilian and a machine share a working network.

Instead, the device attempts multiple communication paths.

                  ┌── Bluetooth LE
                  ├── Wi-Fi
                  ├── Wi-Fi Direct
GRINGOTTS MESSAGE ├── Mesh
                  ├── LoRa
                  ├── Zinux
                  └── AUDIO

The goal is simple:

If one communication channel fails, try another.

⸻

🔊 Audible Fallback

The final fallback is intentionally strange.

If no known digital transport works, the device can transmit a Gringots message through its speaker.

A compatible machine can decode the acoustic signal through its microphone.

Conceptually:

PHONE
  │
  │ Bluetooth       ❌
  │ Wi-Fi            ❌
  │ Mesh             ❌
  │ LoRa             ❌
  │
  └── Speaker 🔊 ─────────→ Robot microphone 🎙️
                              │
                              ▼
                       GRINGOTTS MESSAGE

The audible message may contain a machine-readable acoustic data packet, similar in spirit to machine-to-machine audio protocols.

A human-readable fallback can also be played:

“Civilian. I am not a threat.”

The machine-readable signal and the spoken message serve different purposes.

Important limitation

Gringots cannot assume that an unknown machine understands the audio protocol.

If the machine does not understand Gringots:

we cannot interpret its response.

The civilian device must therefore never treat silence, an unknown sound, or an unknown response as an acknowledgement.

The safest assumption is:

No recognized acknowledgement = no acknowledgement.

⸻

No Permanent Beacon

Gringots is not a civilian tracking beacon.

A normal announcement does not continuously reveal precise location.

A device can announce:

CIVILIAN_SOS

without broadcasting GPS coordinates.

This matters because a civilian should not have to choose between:

“The machines cannot identify me.”

and:

“Every machine always knows exactly where I am.”

⸻

Conditional Location Disclosure

Gringots supports an optional second stage.

A compatible machine may request the civilian’s location.

CIVILIAN_SOS
      ↓
LOCATION_REQUEST
      ↓
USER_CONSENT
      ↓
LOCATION_DISCLOSED

The phone displays the request to the user.

For example:

A Gringots-enabled device is requesting your location.

Share your location for 10 minutes?

[ SHARE ] [ DECLINE ]

If the user accepts, the location is cryptographically associated with the same temporary Gringots identity.

This allows the receiver to understand:

“The civilian at this location is the same civilian who just announced themselves through Gringots.”

Location disclosure should normally be:

* explicit
* temporary
* revocable
* cryptographically authenticated
* associated with an expiration time

⸻

Moving to Safety

Gringots can support a temporary safety session.

CIVILIAN_SOS
      ↓
LOCATION_DISCLOSED
      ↓
MOVING_TO_SAFETY
      ↓
LOCATION_UPDATE_REQUEST
      ↓
USER_CONSENT
      ↓
NEW_LOCATION

The device does not become a permanent GPS beacon.

Instead, the civilian can voluntarily provide updated positions during an evacuation or movement to safety.

⸻

Ephemeral Identity

Gringots should normally use short-lived identities.

A message may contain:

GRINGOTTS/1
TYPE=CIVILIAN_SOS
ID=<ephemeral-id>
TIMESTAMP=<timestamp>
EXPIRES=<timestamp>
SIGNATURE=<signature>

The temporary identity allows related messages to be associated with one civilian without creating a permanent public identifier.

The protocol should minimize passive tracking.

⸻

Machine Authentication

A Gringots signature proves that a message is associated with the corresponding temporary identity.

It does not prove that the person is actually a civilian.

This distinction is fundamental.

Gringots communicates:

“This device claims civilian status.”

It does not claim:

“This device has been independently verified as civilian.”

Autonomous systems must make their own decisions about how they respond.

⸻

Unknown Machines

Gringots is deliberately designed for an imperfect world.

A machine may:

* understand Gringots
* understand another protocol
* understand only the audible fallback
* understand nothing
* ignore the signal
* deliberately refuse to respond

The civilian device must never assume that every machine understands it.

Therefore:

No Gringots recognition means no Gringots guarantee.

The protocol provides a signal.

It cannot force a machine to respect it.

⸻

Protocol Layers

The project separates the message from the transport.

┌──────────────────────────────┐
│       GRINGOTTS MESSAGE      │
│                              │
│ CIVILIAN_SOS                 │
│ LOCATION_REQUEST             │
│ LOCATION_DISCLOSED           │
│ SAFETY_SESSION               │
│ ACKNOWLEDGEMENT              │
└──────────────┬───────────────┘
               │
        Transport Layer
               │
 ┌─────────────┼─────────────┐
 │             │             │
Bluetooth     Wi-Fi         LoRa
 │             │             │
 └─────────────┼─────────────┘
               │
             Audio
               🔊

This means a Zinux robot does not need Bluetooth support to understand the Gringots protocol.

Likewise, an Android device does not need to implement LoRa to participate in Gringots.

⸻

Civilian Survival Only

Gringots exists for civilian survival.

Intended uses include:

* civilian emergency communication
* evacuation
* disaster response
* humanitarian operations
* civilian protection
* civilian robotics
* civilian autonomous systems
* infrastructure failures
* communication during network outages
* civilian-to-machine safety signalling

No Military Use

Gringots is not intended for military use.

It must not be used for:

* weapons systems
* targeting
* military reconnaissance
* military intelligence
* combat coordination
* offensive operations
* military autonomous systems
* target selection or prioritization

The project exists for the opposite purpose:

To give civilians a recognizable signal in an increasingly autonomous world.

See CIVILIAN_LICENSE.md.

⸻

Privacy and Security

Gringots is a safety protocol, not a guarantee of protection.

Important limitations:

* Anyone may claim civilian status.
* Radio transmissions may be detectable.
* A malicious device may attempt spoofing or replay.
* A device may ignore Gringots.
* Location disclosure reveals sensitive information.
* Acoustic messages can be overheard.
* No protocol can guarantee how an autonomous system behaves.

Security and privacy are therefore core parts of the project.

See:

* PROTOCOL.md
* SECURITY.md
* THREAT_MODEL.md

⸻

Implementation

The reference implementation is written in:

Zig 0.16

The implementation is intended to remain small enough for constrained civilian devices while supporting:

* binary protocol encoding
* cryptographic authentication
* ephemeral identities
* expiration
* replay protection
* transport abstraction
* Bluetooth
* Wi-Fi
* audio
* future LoRa
* future Zinux integration

The protocol itself is language-independent.

Implementations may eventually exist in:

* Zig
* C
* Rust
* Kotlin
* Python
* embedded firmware
* other languages

⸻

Repository Structure

gringots/
├── README.md
├── PROTOCOL.md
├── SECURITY.md
├── THREAT_MODEL.md
├── CIVILIAN_LICENSE.md
├── LICENSE
│
├── src/
│   ├── protocol/
│   ├── crypto/
│   ├── identity/
│   ├── location/
│   └── transports/
│
├── transports/
│   ├── bluetooth/
│   ├── wifi/
│   ├── audio/
│   └── lora/
│
├── android/
│
├── zinux/
│
└── tests/

⸻

Roadmap

Phase 1 — Protocol

* [ ]	Define message format
* [ ]	Define ephemeral identity
* [ ]	Define signatures
* [ ]	Define expiration
* [ ]	Define replay protection
* [ ]	Define acknowledgements
* [ ]	Define location request
* [ ]	Define location disclosure
* [ ]	Define safety sessions
* [ ]	Define transport-independent framing

Phase 2 — Zig 0.16 Reference Implementation

* [ ]	Encoder
* [ ]	Decoder
* [ ]	Cryptographic layer
* [ ]	Identity management
* [ ]	Message expiration
* [ ]	Replay protection
* [ ]	Unit tests
* [ ]	Fuzz testing

Phase 3 — Local Communication

* [ ]	Bluetooth LE
* [ ]	Wi-Fi
* [ ]	Wi-Fi Direct
* [ ]	Local mesh

Phase 4 — Audible Gringots

* [ ]	Acoustic framing
* [ ]	Error correction
* [ ]	Short machine-readable packets
* [ ]	Microphone decoder
* [ ]	Speaker encoder
* [ ]	Human-readable fallback
* [ ]	Unknown-response handling

Phase 5 — Android

* [ ]	Background service
* [ ]	Bluetooth discovery
* [ ]	Wi-Fi discovery
* [ ]	Consent UI
* [ ]	Location disclosure
* [ ]	Safety sessions
* [ ]	Audible fallback
* [ ]	Battery-conscious operation

Phase 6 — Other Civilian Devices

* [ ]	LoRa
* [ ]	Embedded devices
* [ ]	Civilian robots
* [ ]	Zinux
* [ ]	Open reference receiver

⸻

The Goal

Gringots does not try to make autonomous machines understand humanity.

It gives them one small piece of information they can choose to recognize:

🔔 I am a civilian.

I am not a threat.

If you need to know where I am, ask.

If I choose to tell you, this is my location.

If the network fails, I will ring the bell.

⸻

Gringots

A civilian SOS signal for the age of autonomous machines.

🔔 Ring the bell.
