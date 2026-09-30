# TrustMe 1.3.5-resilientqueue

The live game showed Arciela in the party and a successful Arciela II cast,
while TrustMe remained paused on "Arciela II: no party confirmation after
cast". The spell and NPC names differ; 1.3.4 was waiting for the wrong name.

## Changes

- Recognize II spells whose party NPC names omit II, including Arciela II ->
  Arciela. Spell names and IDs remain distinct. For an active summon, a
  base-name alias must have a newly joined server ID. A pre-existing ambiguous
  family is reported as already present rather than labelled an exact variant.
- Independently confirm a matching successful completed Trust cast plus its
  newly started recast. Require a self-target result with a normal success
  message, rather than any category-4 action. A missing party name alone can
  no longer freeze this successful cast.
- When confirmation is genuinely missing, issue two ordinary /ma rechecks,
  1.5 seconds apart after the existing recovery guard. Never send per frame,
  inject packets, or bypass game restrictions. Still-unknown outcomes pause
  explicitly after the rechecks and retain pending entries.
- A lost cast result past the generous watchdog retries the same trust.
  Late duplicate start packets for a recently completed spell still on recast
  cannot create a false wait for another spell.
- `/tme status` now prints actual party names, server IDs and active flags.

The timing that worked for you is retained: observed completion plus a
three-second recovery guard. Fast Cast continues to shorten the sequence.
The old eight-second interval and cast-bar idle gate remain absent.

## Install and test

1. Extract the ZIP's trustme folder into C:\Ashita\addons, replacing addon files.
   Keep C:\Ashita\config\addons\trustme intact; it holds saved settings.
2. Run `/addon reload trustme`, then `/tme status`. Expect version
   `1.3.5-resilientqueue`.
3. Run your existing "5 Buffs" profile while standing still and out of combat:
   Koru-Moru, Qultada, Joachim, Arciela II, Star Sibyl. Existing members are
   skipped. Arciela should no longer hold up Star Sibyl.

Optional diagnostics:

```
/tme debug on
/tme status
/tme current
/tme debug off
```

Debug is off by default and prints concise timestamped state transitions.
`/tme clear` cancels pending work; a dispatched cast cannot be recalled.
`/tme resume` resumes the queue after an actual failure has been resolved.

Profiles, favorites, trust data and settings format are preserved. No personal
settings are included. Relative to 1.3.4, only src/task.lua and trustme.lua change
among the Lua files.

## Verification

37 automated checks passed under LuaJIT 2.1, including compilation of all
shipped Lua files. The tests reproduce the previous Arciela II stall using
your actual profile and the observed party name, then verify this build
completes it. They also cover missing packets, unreadable names, failed cast
results, two bounded rechecks, interruptions, stale packets, duplicates,
recasts, cancellation, zoning, death and full parties.

The name mismatch was observed in the running client. These test results are
simulations; an in-game run of the revised build confirms the actual outcome.

Sources compared with the installed addon and SDK:

- https://github.com/loonsies/trustme
- https://github.com/AshitaXI/Ashita-v4beta/blob/main/plugins/sdk/Ashita.h
- https://github.com/ThornyFFXI/tTimers/blob/main/actionpacket.lua
- https://github.com/LandSandBoat/server/blob/base/scripts/globals/trust.lua
- https://github.com/LandSandBoat/server/blob/base/src/map/entities/battle_entity.cpp

The Arciela party-name evidence came directly from your running game.
