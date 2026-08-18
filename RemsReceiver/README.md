# Rems Receiver v2.8

Version 2.8 changes: No more text on startup/load

A Windower 4 addon for retrieving Rem's Tales from **Monisette in Port Jeuno**.

Rems Receiver supports:

- Retrieving a specific quantity of a chapter.
- Retrieving all stored copies of one chapter.
- Retrieving every stored Rem's Tale from Chapters 1-10.
- Retrieving all stored copies of only selected chapters.
- Queuing several chapter/quantity requests in one command.
- Inventory-space preflight checks.
- Partial-stack-aware inventory calculations.
- A live HUD during automated retrieval.
- Completion summaries and an optional completion sound.
- Manual stop/cancel and retry controls.
- A separate debug-privilege companion addon for protected debugging.
- Monisette interactions both with and without gear already traded.

---

## Installation

Extract the package into your Windower `addons` directory.

The final layout should look like:


Windower\
└── addons\
    ├── RemsReceiver\
    │   ├── RemsReceiver.lua
    │   └── complete.wav
    │
    └── RemsReceiverDebug\
        └── RemsReceiverDebug.lua


The `RemsReceiverDebug` folder is only required when privileged debug logging is needed.

### Load Rems Receiver

In-game:


//lua load RemsReceiver


To reload it after replacing or editing the Lua file:


//lua reload RemsReceiver


To unload it:

//lua unload RemsReceiver


For a list of addon commands:


//rr help


---

# Retrieval Commands

## Retrieve a Specific Quantity


//rr <chapter> <quantity>


Examples:


//rr 1 5
//rr 2 3
//rr 6 10
//rr 10 1


//rr 1 5 retrieves 5 Rem's Tale Chapter 1.

Valid chapters are 1 through 10.

---

## Retrieve All of One Chapter


//rr <chapter> all


Examples:


//rr 1 all
//rr 6 all
//rr 10 all


Example:

//rr 6 all

retrieves every Chapter 6 that Monisette currently has stored.

---

## Retrieve Every Stored Rem's Tale

//rr all


This retrieves all stored Rem's Tales for Chapters 1 through 10.

Before retrieving the first chapter, Rems Receiver checks whether the entire planned retrieval will fit in your inventory.

If there is not enough room, the operation is stopped before any Rem's Tales are retrieved.

---

## Retrieve All of Selected Chapters

//rr all <chapter> <chapter> ...

Examples:

//rr all 1 2 5 6
//rr all 6 7 8 9 10

Example:

//rr all 1 2 5 6

retrieves all stored copies of Chapters 1, 2, 5, and 6 while leaving the other chapters stored with Monisette.

---

## Queue Multiple Requests

Multiple chapter/quantity pairs can be placed in one command:

//rr <chapter> <quantity> <chapter> <quantity> ...


The quantity for any chapter can also be `all`.

Examples:


//rr 1 5 2 3
//rr 1 5 2 3 6 all
//rr 1 all 2 all 10 5


Example:

//rr 1 5 2 3 6 all


queues:


5 x Chapter 1
3 x Chapter 2
ALL stored Chapter 6


The queued job performs an inventory preflight before beginning.

---

# Information Commands

## List Stored Rem's Tales

//rr list

Reads Monisette's current stored Chapter 1-10 counts and displays them in chat.

No Rem's Tales are intentionally retrieved by this command.

---

## Check Inventory Space


//rr space


Shows inventory information for the Rem's Tales currently stored with Monisette, including:

- Total stored Rem's Tales.
- Available inventory slots.
- Space available in existing partial Rem's Tale stacks.
- New inventory slots required.
- Whether a full `//rr all` operation will fit.

The inventory calculation is stack-aware.

For example, if an existing Chapter 1 stack has room for 2 more tales, those 2 tales do not require a new inventory slot.

---

## Combined Stored/Space Report

//rr missing

Displays both the stored Chapter 1-10 counts and the inventory-space report.

This is useful before running:

//rr all

---

## Current Status

//rr status

Displays the current Rems Receiver state.

During an active operation it reports information such as:

- Current job type.
- Current chapter.
- Processing stage.
- Number retrieved so far.
- Planned total.

It also reports whether debug privilege is currently `ACTIVE` or `LOCKED`.

---

# Job Control Commands

## Stop an Active Job

//rr stop

Stops an active retrieval job.

If the current retrieval packet has **not** been sent yet, the job stops immediately.

If the current chapter retrieval has already been sent to Monisette, that retrieval is allowed to finish and the addon stops before starting the next chapter.

---

## Cancel an Active Job


//rr cancel


`cancel` is an alias for:


//rr stop


---

## Retry the Current Step


//rr retry


Retries the current Monisette interaction when an automated job has stalled before the retrieval choice was sent.

Rems Receiver also contains automatic interaction retries, but this command allows a manual retry when needed.

If the current retrieval choice has already been sent, the addon will not send it a second time.

---

# HUD Commands

The live HUD displays progress during automated jobs.

Examples of HUD information include:


Rems Receiver v2.8
ALL | sent
Ch.6 | 6/10 | 89/173 received


## Enable HUD


//rr hud on


## Disable HUD

//rr hud off


## Show Current HUD Setting

//rr hud

---

# Completion Notification Commands

Rems Receiver includes `complete.wav` for an optional completion notification.

## Enable Completion Notification

//rr notify on


## Disable Completion Notification

//rr notify off


## Show Current Notification Setting

//rr notify


Keep `complete.wav` in:

Windower\addons\RemsReceiver\complete.wav


---

# Logging

The main log is written to:

Windower\addons\RemsReceiver\RemsReceiver.log


## Clear the Log

//rr clearlog


This clears the existing Rems Receiver log and starts a fresh one.

---

# Privileged Debugging

Debug logging is intentionally protected by a separate companion addon.

Normal Rems Receiver use does **not** require the debug companion.

Trying to enable debug without the companion loaded will be refused.

## Enable Debug Privilege

Load the companion:

//lua load RemsReceiverDebug


You should see a message indicating that Rems Receiver debug privilege is active.

Then enable debug logging in the main addon:

//rr debug


Debug data is written to:

Windower\addons\RemsReceiver\RemsReceiver.log


## Check Debug Companion Status

//rrdebug status


## Turn Debug Logging Off

//rr debug


Running `//rr debug` again toggles privileged debug logging off.

## Revoke Debug Privilege

Unload the companion:

//lua unload RemsReceiverDebug


The main addon uses a short-lived heartbeat token from the companion.

If `RemsReceiverDebug` is unloaded, crashes, or stops updating the token, Rems Receiver automatically revokes debug privilege and disables active debug logging after the heartbeat expires.

The heartbeat file is:

Windower\addons\RemsReceiverDebug\debug.token


It is managed automatically and normally does not need to be edited or deleted manually.

---

# Command Reference

| Command | Description |
|---|---|
| `//rr help` | Display command help. |
| `//rr <chapter> <quantity>` | Retrieve a specific quantity of one chapter. |
| `//rr <chapter> all` | Retrieve all stored copies of one chapter. |
| `//rr all` | Retrieve all stored Chapters 1-10. |
| `//rr all 1 2 5 6` | Retrieve all stored copies of only the listed chapters. |
| `//rr 1 5 2 3 6 all` | Queue multiple chapter/quantity requests. |
| `//rr list` | Display Monisette's stored Chapter 1-10 counts. |
| `//rr space` | Display inventory capacity and slots required. |
| `//rr missing` | Display stored counts plus the inventory-space report. |
| `//rr status` | Display current job and debug-privilege status. |
| `//rr retry` | Retry the current Monisette interaction step. |
| `//rr stop` | Stop the current retrieval job. |
| `//rr cancel` | Alias for `//rr stop`. |
| `//rr hud on` | Enable the progress HUD. |
| `//rr hud off` | Disable the progress HUD. |
| `//rr hud` | Display the current HUD setting. |
| `//rr notify on` | Enable the completion notification. |
| `//rr notify off` | Disable the completion notification. |
| `//rr notify` | Display the current notification setting. |
| `//rr clearlog` | Clear `RemsReceiver.log`. |
| `//rr debug` | Toggle debug logging; requires `RemsReceiverDebug`. |
| `//rrdebug status` | Check the debug companion heartbeat/status. |
| `//lua load RemsReceiverDebug` | Grant debug privilege. |
| `//lua unload RemsReceiverDebug` | Revoke debug privilege. |

---

# Inventory Safety

Rems Receiver checks inventory capacity before automated retrieval.

The calculation accounts for:

1. Empty inventory slots.
2. Existing partial stacks of each Rem's Tale chapter.
3. The number of tales being requested for each individual chapter.
4. The complete planned job for `//rr all`, selected-all jobs, and multi-request queues.

For whole-job operations, if the complete retrieval cannot fit, the addon stops before retrieving the first tale.

It also rechecks capacity before individual chapter retrievals.

---

# Supported Monisette States

Rems Receiver supports the two manually verified Rem's Tale retrieval menu states:

Menu 385 = normal / no gear traded
Menu 387 = gear already traded to Monisette


The addon sends a retrieval choice only when Monisette returns one of the supported Rem's Tale menu states.

Unexpected Monisette menu states trigger a safety stop instead of blindly sending a retrieval packet.

---

# Examples

Retrieve 10 Chapter 1:

//rr 1 10


Retrieve every stored Chapter 1:

//rr 1 all

Retrieve everything:

//rr all


Retrieve only all Chapters 1, 5, 6, and 10:

//rr all 1 5 6 10

Retrieve 5 Chapter 1, 3 Chapter 2, and all Chapter 6:


//rr 1 5 2 3 6 all


Check whether everything will fit first:


//rr space


Show counts and space together:


//rr missing


Stop a long `//rr all` operation:


//rr stop


Enable protected debugging:


//lua load RemsReceiverDebug
//rr debug


When finished debugging:


//rr debug
//lua unload RemsReceiverDebug


---

# Recommended Normal Workflow

For everyday use:


//lua load RemsReceiver
//rr missing
//rr all


For one specific chapter:


//rr 6 all


For troubleshooting:


//lua load RemsReceiverDebug
//rr debug


Reproduce the issue, then disable privileged debugging:


//rr debug
//lua unload RemsReceiverDebug


The debug information will be available in:


Windower\addons\RemsReceiver\RemsReceiver.log

