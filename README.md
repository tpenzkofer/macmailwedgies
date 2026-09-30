# macOS Mail stops syncing with Exchange, silently

<https://github.com/tpenzkofer/macmailwedgies>

If you use Apple Mail with an Exchange (EWS) account and notice that **messages
you read on your Mac stay unread on the server**, this is very likely what is
happening to you.

The usual advice is to remove and re-add the account. **Don't** — see
[Do not do this](#do-not-do-this). It works, and it can permanently destroy
recently sent mail.

## The symptom

- You read mail on your Mac. On the web client and your phone it is still unread.
- Messages you sent are missing from the server's Sent Items, though the
  recipients received them fine.
- Flags, moves and deletions made on the Mac never reach the server.
- Mail shows **no error at all**. Nothing appears in the mailbox's sync-issue
  folders. The account looks perfectly healthy.

That silence is the worst part. In the case that prompted this, it had been
running for about **two weeks** before anyone noticed the Mac and the server had
drifted apart.

## The cause

Mail keeps a queue of changes waiting to go to the server, in
`~/Library/Mail/V10/MailData/Envelope Index`, and processes it in order.

When Mail asks Exchange to delete an item the server no longer has, Exchange
answers **EWS `responseCode: 190`** — *item not found*. That is a permanent
condition: retrying cannot change it.

Mail classifies it as a **connection error**, and retries. Forever. Roughly 28
requests per second, with no retry ceiling and no dead-letter path. The log line
says so outright:

```
EWS response error detected - responseClass: <private>, responseCode: 190, messageText: <private>
ECLocalActionReplayer  Replaying delete action <ECTransferMessageAction: 0x…> id = <action-id>,
    num items to delete = 1, transfer type = 3 for 1 items got connection error
```

`got connection error`, for an HTTP 200 response carrying an EWS-level error.

Because the queue is strictly ordered, **nothing behind that one action ever
runs.** Read-marks, flag changes and uploads into Sent Items all pile up behind a
single request that can never succeed.

Drafts are the most reliable trigger: autosave replaces the draft on the server as
you type, so a queued delete referencing the earlier item is already stale when it
runs. But it is not specific to drafts — any queued delete whose target has
already gone produces it, and items disappearing from a shared mailbox is
completely normal. Another device deletes something, a rule files it, a retention
policy expires it. A client that queues deletes must expect this; it is the
common case, not an edge case.

## Confirm you have it

Wedged actions have a consistent signature. This is read-only:

```sh
sqlite3 "file:$HOME/Library/Mail/V10/MailData/Envelope Index?mode=ro" "
SELECT a.ROWID, am.action_phase, m.url
  FROM local_message_actions a
  JOIN action_messages am ON am.action = a.ROWID
  LEFT JOIN mailboxes m ON a.mailbox = m.ROWID
 WHERE a.action_type = 5
   AND am.message IS NULL
   AND am.remote_id IS NOT NULL;"
```

A row means a delete whose local message is gone but which still holds a server
item id — nothing left to act on, and Mail cannot give up on it.

To see it spinning in real time:

```sh
log show --last 15m --predicate 'process == "Mail"' --style compact \
  | grep -i 'Replaying.*action.*id ='
```

An action id repeating over and over is the culprit. That id is what you drop.

## Fix it

```sh
./mailsync-doctor.sh            # diagnose, read-only
./mailsync-doctor.sh --unwedge  # detect, quit Mail, drop the action, reopen
```

`--unwedge` backs up the queue first and preserves your pending read-marks and
sent-item uploads. Mail has to restart, because it replays the action from memory
— deleting the row alone leaves it retrying its cached copy.

Clearing one wedge can reveal the next one behind it, so run it again if the
queue does not drain.

Requires **Full Disk Access** for your terminal.

## Do not do this

**Removing and re-adding the account**, or **Mailbox → Rebuild**, both clear the
jam — by discarding the queue wholesale. That queue contains uploads of messages
you have already sent, whose only copy is on your Mac. They are absent from the
server and from every other device. Destroy the queue and they are gone, with no
warning and nothing in Trash.

In the case behind this repo, two separate incidents had 7 and 10 sent messages
in exactly that state, including attachments of around 2 MB.

These scripts contain no command that will do that to you. Before any drastic
step you take by hand, check what is exposed:

```sh
./mailsync-doctor.sh   # section 3b lists sent mail that exists only locally
```

Save those messages elsewhere first.

## Tools

| Command | What it does |
| --- | --- |
| `./mailsync-doctor.sh` | Full read-only diagnosis: queue, wedges, locally-held sent mail, sync tokens, folder sizes, search-index backlog |
| `--unwedge` | The supported fix. Detect, quit Mail, drop, reopen |
| `--watch` | Poll the queue live and watch it drain |
| `--check` | Quiet health check for `launchd`/`cron`; exit 1 and a notification when wedged |
| `--drop-action <id>` | Drop specific action ids, e.g. one named by the log |
| `--analyze` | Rebuild SQLite query-planner statistics (the Envelope Index ships without them) |
| `--recount` | Reset the flagged-mailbox badge cache |

There is deliberately **no command that empties the action queue**. Clearing it
wholesale does unstick the sync, and it is what removing the account amounts to —
but it discards pending Sent Items uploads along with everything else, and those
are sometimes the only copy of a sent message. `--unwedge` removes just the one
action that cannot complete, and leaves the rest of the queue to drain.

The diagnosis also reports EWS sync-token sizes and folder sizes. Those are
**observations, not diagnoses** — an oversized token looked like the cause early
on and was not. Clearing tokens did not stop the stalls; removing the wedged
action did.

Everything that writes takes a typed confirmation and backs up first, into
`~/Library/Mail/mailsync-doctor-backups/`.

## What is actually Apple's bug

1. **`190` is treated as transient.** For a delete, *the item is not there* means
   the operation's goal is already met. It should complete, not fail.
2. **No retry ceiling and no backoff.** Re-sent at the round-trip rate, about
   every 40 ms, indefinitely.
3. **One action starves the whole queue.** A failing action should be set aside so
   unrelated changes behind it continue.
4. **Nothing is surfaced.** No error on the account, nothing in the sync-issue
   folders — which already exist for this purpose and stayed empty throughout.
5. **Pending Sent Items uploads are destroyed without warning** by removing the
   account or rebuilding a mailbox.

Also worth knowing: a wedged client issues on the order of **2.4 million futile
`DeleteItem` calls per day** against the Exchange server. If your mailbox is being
throttled, this may be why — and that throttling can then look like a separate,
unrelated problem.

## Scope and caveats

Observed on **macOS 27.0 (26A428)**, Mail data store `V10`, against on-premises
Exchange over EWS. Whether it reproduces on Microsoft 365 or on earlier macOS is
untested — reports welcome.

These scripts read and, on the write paths, modify Apple's own database. That is
unsupported, and Mail may discard some changes when it next rebuilds its index.
Nothing here deletes mail. The write paths edit the action queue, sync tokens, or
cached counters only. Read the script before running a write path.

One thing ruled out with data, since it is the first thing anyone suspects:
**Mail is not queuing duplicate deletes.** Across five captured queue snapshots,
zero server items were targeted by more than one delete action. The duplicate
references present were benign — a read-state change plus a move on the same
message.
