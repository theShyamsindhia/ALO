# Breach — local tactical FPS

Breach is an original single-player bot game included in ALO. Launch it from Games → Breach → Play, or run `swift run alo breach`. Fourfold (Connect 4) is no longer offered in the library. Existing downloaded files are not deleted.

## Play loop

Choose AR-24, VX-9, or P-12 and a bot difficulty. Deploy, then capture the mouse to start the round. Eliminate three guards in Foundry; first to five rounds wins. A death or the 90-second timer awards the opposition a round. Reloading uses reserve ammunition. Concrete walls block shots; low crates block movement but allow standing shots over their top. Bots use cached navigation around cover and a reaction delay when acquiring the player.

WASD moves, Shift walks, mouse aims, left click fires, R reloads, and holding Tab shows match stats. Escape pauses and releases the mouse. Changing applications also pauses. Cmd W closes the dedicated window and restores cursor control. Settings expose loadout, bot difficulty, sensitivity, FOV, effects volume, shadows, and rebindable movement/reload controls.

## Assets

Geometry, weapons, characters, signs, effects and procedural materials are original local assets implemented in `BreachScene.swift` and `BreachAudio.swift`. `Sources/ALO/Resources/Breach/concrete.png` was generated using the built-in image generation tool. Prompt: seamless square albedo texture of weathered grey poured concrete, subtle aggregate, pores, faint horizontal formwork impressions, mottled mineral discoloration, fine hairline cracks; even diffuse illumination, no shadows, perspective, objects, text or border; neutral medium grey, all edges tile seamlessly.

## Current limits

This is local bot combat. It is not a Counter-Strike clone or a completed network shooter. Room multiplayer, teams, network prediction/lag compensation, buying/economy, grenades, jump/crouch, bomb objectives, player animation rigs and competitive matchmaking are not implemented. The game does not advertise a joinable room or write to the Rift Arena leaderboard. These require their own session/protocol design and multi-Mac testing before shipping as online play.

## Verification

`swift build` and `swift test --filter BreachTests`. Tests exercise swept collision, cover height, damage, ammo, reload, round resets, terminal scoring, invalid input and bot navigation bounds. Manual macOS checks cover deployment, capture, Escape, settings and Cmd W. GPU performance on other Mac models and multiplayer are not covered by those checks.
