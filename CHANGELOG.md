# Changelog

## 0.3.0
- Loot valued at AH prices from PriceLog or MatTooltip; old prices (over 3 days) are flagged.
- Shows NeutralFlip's flip value and MatTooltip's verdict for your loot.
- `/goldspot spots` compares your farming spots.
- No timers running when you are not farming.
- A short guide on first login; one shared display-bar entry.
- `/goldspot debug` checks your setup: client version, every game API the addon needs, and which of Kenny's other addons it is working with.
- A loud chat warning if this client is missing an API the addon needs, instead of failing silently.
- English text now lives in `Locales/enUS.lua`, ready for translations.
- Shared code (KennyShared) is identical in every addon of the family and checked in CI, along with every Blizzard API call (against the Forever UI source) and every DBM/BigWigs/Questie API call (against their source).

## 0.2.0
- LibDataBroker display (Titan Panel, ChocolateBar, Bazooka...): live gold/hour; tooltip shows the session; left-click shows/hides the window, right-click starts or pauses.
- Tests now fail CI on any luacheck warning, and the API check also covers LibDataBroker calls.

## 0.1.0 (first public release)
- Added the CurseForge and Wago project IDs to the TOC for automatic packaging, and an icon for the AddOns list (`media/icon.tga`).
- **Renamed from FarmTracker** (GitHub pre-release FarmTracker-v0.1.0 in masterred92/wow-forever-addons) so the name is unique on CurseForge, Wago and GitHub. The folder, TOC title, slash commands (`/goldspot`, `/kspot`), SavedVariables (`KennyGoldPerSpotDB`) and frame names all changed. Sessions saved by FarmTracker 0.1.0 are not carried over, because the folder rename gives a new SavedVariables file and that build was never released on CurseForge.
- Session gold/hour, top items, history per spot, and a "this spot vs your best" verdict. Movable, lockable frame.
- Game version: WoW: Forever 1.60.1 (Interface 16001).
