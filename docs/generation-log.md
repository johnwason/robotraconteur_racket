# Generation log: a Robot Raconteur client for Racket

This repository was written by Claude (Anthropic's Claude Opus 5.5, in Claude
Code), directed by John Wason, in one session over a few hours of active
work. This log
records the prompts, what was built in response, and the reasoning behind the
main decisions.

**Sources.** Prompts are quoted verbatim from the session transcript, except
that local paths and the simulator's address are replaced by placeholders in
angle brackets, such as `<sources>` for the directory of reference checkouts,
or removed. Commit hashes refer to
this repository. The work up to the end of phase 4 was
later compacted into a summary, so its decision notes come from that summary
and the commit messages. Everything after that is recorded
from the session directly. The "why" notes give the reasoning as it was
stated during the work, not a full record of the model's internal process.

## Summary

| | |
|---|---|
| Time | about 2¾ hours of agent working time; the user's input was 53 short prompts (see the statistics below) |
| First working client | about 11 minutes after the first prompt (the first passing test run), committed about 3 minutes later as `06e21ca` |
| Result | 3,245 lines of Racket in the library (`robotraconteur/`), 2,302 lines of Racket tests plus 604 lines of Python test services, a Scribble manual, examples, CI |
| Transports | `rr+tcp`, `rr+ws`, `rr+wss`, `rrs+tcp` (Robot Raconteur node TLS), plus IPv6 discovery |
| History | 43 commits, 3 pull requests, all merged |
| Tests | 102 test cases in 12 stages, run in podman without network access (see the statistics for how they are counted) |
| Published | `robotraconteur` on pkgs.racket-lang.org |

## The AI

| | |
|---|---|
| Model | Claude Opus 5.5 (`claude-opus-5-5`), by Anthropic; training data up to June 2026 |
| Harness | Claude Code, running in the VS Code extension on a Linux workstation |
| Tools the model could use | a shell (`Bash`), file reading and editing (`Read`, `Write`, `Edit`), web fetch and search, asking the user a question, and stopping background tasks |
| Agents | one agent throughout; no subagents were used |
| Context | the conversation was automatically compacted into a summary once, after the ServiceTest port (end of phase 4) |
| Safety | tool calls ran under Claude Code's permission system; one command (an `rm -rf` inside a container script) was blocked by its safety check |

**Who did what.** The model wrote all the code, tests, documentation,
commit messages and pull request descriptions. It ran every build and test
itself, through the shell, in podman containers. The user steered the work:
several prompts set the direction or caught real problems, listed under
"Decisive user interventions" below. The user also gave permissions (the
GitHub repository and token, access to the simulator), merged the pull
requests, registered the package on pkgs.racket-lang.org, ran examples on
their own machine, reported the core bugs upstream, and edited this log.

## Decisive user interventions

These prompts changed what was built, or caught problems the model had not
raised on its own. Each is quoted in full in its phase.

### Technical steering

These draw on the user's knowledge of Robot Raconteur and its
implementations.

- **Binary test vectors, not literal arrays** (phase 4). This set the
  approach for the ServiceTest port. The user also corrected the target
  files (client tests, not service tests) and pointed to the C++ test server
  library as the test target, which made the in-process FFI harness
  possible.
- **robotraconteurlite as the WebSocket reference** (phase 2). Its treatment
  of frames as a byte stream led to the thin transport design.
- **"rrs+ws was a dead end"** (phase 5). This saved implementing a transport
  that would not have been used.
- **Embedding the two root certificates** (phase 7). This defined what
  `rrs+tcp` needed to trust by default.
- **"Does the tcp connector test different ipv6 zone ids?"** (phase 10). This
  exposed that zoneless link-local URLs failed. "The user won't know the
  correct scope id" set the requirement to race every interface, as the core
  does.
- **"What is the TCP timeout?"** and **"connect should always timeout after
  around 5-10 seconds"** (phase 11). These exposed that a connect could hang
  for about two minutes, or forever on a silent server.
- **Asking for discovery and IPv6 multicast** (phase 9), which led to the
  FFI socket layer.
- **Reynard as the Quick Start device** (phase 14). This replaced the model's
  first version, which reused a Python service the user did not want.

### Process and governance

- **Network permissions, scoped narrowly** (phases 6 and 13): the public
  `rr+wss` test server, then the simulator's published ports. The user also
  provided the simulator and its README, so ports were not guessed.
- **Requiring the AI disclosure in the README and manual** (phase 12).
- **"Keep a clean git history so we can rewind, and iterate your design"**
  (phase 4), which set the one-commit-per-step practice used throughout.

## Session statistics

Counted from the session transcript and the repository. The interaction
figures cover the session up to the prompt asking for this log, so writing
and revising the log is not included. The repository figures are for `main`
after pull request #3.

**Interaction**

| | |
|---|---|
| User prompts | 53; 2 interrupted the work in progress |
| User input | 691 words typed: a median of 11 words per prompt, and 26 of the 53 prompts were 10 words or fewer. The only pasted text was 13 words (the package site's challenge expression) |
| Model responses | 491 |
| Agent working time | about 2 hours 45 minutes: from each prompt to the agent's last action before the next prompt, summed over all prompts |
| User attention | not measured, and not the same as the agent's time. The user reports doing other work in parallel during the session. The time between the agent finishing and the next prompt was under 2 minutes for 39 of 52 turns (median about 1 minute), but that shows when prompts were sent, not how much attention they took |
| Timing of the early commits | phases 1 to 4 took the first hour of the session; their 19 commits fall within 40 minutes. Git shows them in the machine's local time zone (UTC−5). The history was not rewritten: author and committer dates match, and the transcript has no rebase, reset or amend. After phase 4 the session was idle for about five hours until the next prompt, which the agent working time leaves out |
| Questions the model asked the user | one through the question tool; confirmations were also given in text before the ServiceTest work, as requested |

**Tool calls: 498**

| Tool | Calls | Used for |
|---|---|---|
| Bash | 420 | builds, tests, git, podman, editing files with scripts |
| Write | 55 | new files |
| Edit | 6 | small in-place changes |
| Read | 6 | reading files and images (camera frames) |
| TaskStop | 4 | stopping hung or stale background runs |
| ToolSearch | 3 | loading tools |
| WebFetch | 2 | checking the package page |
| WebSearch | 1 | looking for an existing loopback robot driver (phase 3) |
| AskUserQuestion | 1 | a question when the user planned to switch computers |

Within the shell calls: 122 `podman run` invocations, 8 image builds, 30 runs
of the full test script, 41 targeted `raco test` runs, and 30 shell calls that
made commits. Eight of those made more than one commit (one made four), giving
the 40 commits by the model.

**Tokens**

| | |
|---|---|
| Output | about 538,000 |
| Input | about 153.3 million, almost all cache reads (152.3 million), plus 1.0 million cache writes and about 1,100 uncached |

The input is large because every response re-reads the whole conversation,
including long tool outputs; caching keeps most of that cheap.

**Result**

| | |
|---|---|
| Files | 68 tracked |
| Racket | 6,362 lines: 3,245 in the library, the rest tests and examples |
| Other | 2,438 lines of Python, shell, Scribble, Markdown, CI and Dockerfile |
| Commits | 43: 40 by the model, 3 pull request merges by the user |
| Pull requests | 3 merged |
| CI runs | 8, all passed |
| Tests | 102 test cases. A full offline run reports 164 results: the 21-test client suite runs once per transport (4 times), and the one online `rr+wss` test runs only in the separate online check (102 − 21 + 84 − 1 = 164) |

## Ground rules given at the start

> Out of curiosity I would like to see if a simple Robot Raconteur client can be implemented for the racket language.
>
> Use this folder as your workspace. Do not modify anything outside of this folder, and do not contact any local network device. Use the github "johnwason" and "robotraconteur" organization for reference. See `<sources>` for sources. Also consider https://github.com/johnwason/robotraconteur_typescript and https://github.com/johnwason/robotraconteur_typescript_node . Use podman for dependencies. Use a dockerfile so you don't keep hitting servers

These constraints shaped everything that followed:

- **The workspace boundary.** Nothing outside the project folder was modified. Reference checkouts were mounted read-only into containers. At several points the work checked that `git status` in the user's core checkout was still clean.
- **No local network devices.** Every test container runs with `--network none`. When network features had to be tested (TLS, WebSocket, discovery, link-local addressing), the test setup was built *inside* the container's own network namespace instead of using the real network. The two later exceptions were granted explicitly and kept narrow: the public `wstest2.wasontech.com` server, and the training simulator's published ports.
- **Dependencies through a Dockerfile**, built once, so package servers weren't hit on every run.

## Phase 1: the first client

**What was built:** a Message Version 2 codec, a service definition (robdef) parser, value packing, and a client with properties, functions, events, callbacks, object references, wires, pipes and generators. Tests run against a Python Robot Raconteur service in a container. Commit `06e21ca`.

**Decisions:**
- **Message Version 2 only.** It's the simplest format the core still speaks: the client advertises only V2 and servers fall back to it. Version 4 and string tables were left out.
- **No code generation.** Like the Python client, the Racket client reads service definitions from the service at connect time and converts values dynamically. Racket is dynamically typed, so this needed no generator step.
- **References read instead of guessed:** the C++ core source, the TypeScript client, and later robotraconteurlite, for protocol details such as the handshake, the message layout and the WebSocket subprotocol.
- **The Python reference library as the test service**, installed in the image, so the client was tested against the real implementation from the start.

## Phase 2: WebSocket

> websocket client support is fairly important. It should be straightforward to hack it
>
> take a look at robotraconteulite

**What was built:** an RFC 6455 client (`websocket.rkt`) exposing the connection as a byte stream, so the rest of the client is unchanged. Commit `969fe66`.

**Why this design:** robotraconteurlite treats WebSocket binary frames as a plain byte stream carrying ordinary messages, so the transport could be a thin port wrapper. No `Origin` header is sent, as the servers expect from non-browser clients.

## Phase 3: real devices

> consider robotraconteur/reynard-the-robot and robotraconteur/robotraconteur_abstract_robot_python, with the loopback test device. See if you can interact using racket in your podman

**What was built:** interop tests against Reynard the Robot, and `test/loopback_robot.py`, a hardware-free `AbstractRobot` driver. Commit `c2ae56d`.

**Decision:** no ready-made "loopback test device" was found, so one was written: every joint command is fed back as the measured position. That way jog, trajectory and position-command modes can all be checked against the robot's reported state.

**Problem found:** the trajectory test was intermittently failing. The fix set its tolerance from the driver's 10 ms sampling step (`c3a7d33`).

## Phase 4: porting the core's own client tests

> look at `<sources>/robotraconteur` . This has an improved testing scheme checked out that uses a binary block. Are you able to implement ServiceTest.py, ServiceTest2.py, and ServiceTest3.py? Ignore memories, they aren't widely used. Use the binary blob, don't copy the literal arrays like the current master. Confirm you understand before beginning work
>
> That was my mistake, ServiceTestClient.py, ServiceTestClient2.py, and ServiceTestClient3.py are your targets. Confirm before making any changes
>
> the C++ core builds an executable robotraconteur_test_server and a library robotraconteur_test_server_lib you can use as the target
>
> ok keep your work inside podman, keep a clean git history so we can rewind, and iterate your design

**What was built:**
- A reader for the binary test-vector file, cross-checked bit for bit against the Python reader for all 114 vectors.
- An FFI harness that runs the C++ test server inside the Racket test process.
- Ports of all three client test files (26 tests).
- The library features those tests needed: locks, generator abort, pipe acknowledgements, full remote error details, multidimensional pod fields, and object reference type refresh.

Commits `7fd056a` to `ea2ab7a`.

**Decisions:**
- **Confirmed the scope before starting**, as asked, and then again after the target was corrected.
- **The C++ server built inside podman** from the read-only checkout, with output kept in the workspace.
- **One commit per step**, so the history can be rewound.
- **A breaking API change, called out:** `rr-wire-in-value` now raises `ValueNotSet` like the reference clients, instead of waiting; waiting moved to `rr-wire-wait-in-value`.
- **Mutation checks:** deliberately wrong data was fed to the verifiers to confirm they can actually fail.

**Findings reported to the user:**
- The Python `TestMonitorLock` can't fail as written: its worker thread assigns to local variables. The Racket port asserts the intended behavior instead.
- An event fired 200 ms after a call can arrive on the next test's connection.
- A blocking listener stalls the connection's dispatch thread. This became a documented rule.

## Phase 5: questions and scoping

> how does the threading model work?
>
> consider the tls tests in Python in core. don't code, just explain what they do
>
> rrs+ws was a dead end so forget that format, don't generate just report

These were explanations only, read from the source. The threading answer also listed weak spots, such as a non-atomic `hash-update!` and a polling wait on wire values. The TLS answer walked through `test_tcp_tls.py` step by step, and was revised to drop `rrs+ws` when told it was a dead end.

## Phase 6: `rr+wss`

> you have permission to contact wstest2.wasontech.com. Implement rr+wss

**What was built:** standard TLS under the existing WebSocket client, using Racket's `openssl` library, plus `rr-make-ssl-context` for trusting extra certificates. Commit `ffcaaa8`.

**Decisions:**
- **The public server only for a separate online check** (`run_online_tests.sh`). The main suite stays offline: it runs the full 21-test client suite over `rr+wss` through a local TLS relay with a throwaway certificate.
- **Tests that verification really happens:** an untrusted certificate and a wrong hostname are both rejected, and the tests check that the error is "certificate verify failed", not a refused connection.
- **Why `rr-make-ssl-context` exists:** Racket "seals" its secure context, so extra roots can't be added to it.

## Phase 7: `rrs+tcp`, Robot Raconteur's own TLS

> let's implement rrs+tcp. You will need to embed the two root certificates

**What was built:**
- The STARTTLS exchange.
- Certificate checks matching the C++ core: the chain, the custom critical extensions for each position, and the node certificate's CN.
- The two root certificates, unmasked from the core's header and embedded with their fingerprints.

Commits `ac9a293`, `1981af6`.

**Decisions:**
- **Driving libssl through the FFI.** Node certificates carry custom *critical* extensions that stock OpenSSL rejects, and Racket's `openssl` library has no verify callback. So the TLS layer talks to libssl directly, reusing the libraries Racket already loads.
- **No real certificates were available, so a test PKI was built** with the same structure (`make_test_pki.sh`), plus three deliberately broken node certificates.
- **A baseline first:** the Python reference client was shown to accept the test chain with the test root and reject it without. Only then was the Racket client tested against the same chain.
- **Mutation checks:** disabling each verification rule made exactly the matching test fail.

**Findings:**
- In a root container the core reads node certificates from the *system* config directory.
- `NodeDirectories.cpp:288` reads the wrong environment variable for `user_state_dir`. The user reported this to the core repository:

> I reported the bugs to the main repos

## Phase 8: GitHub, license and CI

> I created johnwason/robotraconteur_racket and gave you a token
>
> add apache 2.0 license and actions ci

**Decisions:**
- **The token never touched git config.** It was passed per command as a header; it was never stored in the remote URL or written to disk elsewhere.
- **The history was scanned for secrets and private keys before the first push.** The user was told what becomes public: the unmasked root certificates (public certificates anyway) and the test-vector file from an unmerged branch.
- **CI caches only the self-contained 29 MB test server library**, not the 1.2 GB build tree, keyed on a pinned core commit.
- **`RR_REQUIRE_CPP_SERVER=1`** makes CI fail rather than skip when the server is missing.
- **The online test job may fail without failing the workflow**, so an outage of the public server doesn't block changes.

## Phase 9: discovery

> Can we attempt discovery? Can racket do ipv6 multicast?

**Findings first:**
- Tested directly: `racket/udp` can only join IPv4 multicast groups.
- From the source: nodes discover over IPv6 link-local multicast by default, and never announce from loopback.

**What was built:** discovery over sockets made through the C library via the FFI, waited on with `unsafe-fd->evt` (`discovery.rkt`). Commit `bc4bc2e`.

**How it was tested without touching the LAN:**
- The container got `NET_ADMIN` and created tap interfaces in its *own* network namespace, still with `--network none`.
- A tap has no carrier until something holds it open, so `tap_sink.py` holds it open and drops every frame.
- The Python reference client was confirmed to discover nodes on this setup before the Racket code was trusted.

> push to a new branch

## Phase 10: link-local zones

> does the tcp connector test different ipv6 zone ids?
>
> yes make this improvement on the discovery branch. The user won't know the correct scope id

**Decision:** match the core, which tries a zoneless link-local address on every interface. The behavior was measured first: the right zone connects, a wrong zone *hangs* until the TCP timeout, and no zone fails at once. So the zones are raced in parallel, each attempt under its own custodian so losers can be shut down. Trying zones one at a time could stall for minutes. Commit `a51227e`.

## Phase 11: connect timeouts

> what is the TCP timeout?
>
> connect should always timeout after around 5-10 seconds, otherwise the user is stuck waiting fo several minutes if the service is not availabe or there is a typo

**Answer first:** about 127 s, from Linux's `tcp_syn_retries` default, since Racket's `tcp-connect` has no timeout. The core uses 5 s.

**What was built:**
- A 5 s TCP connect limit, like the core.
- A 10 s limit on the whole connect. This also covers servers that accept a connection and never answer, which previously hung forever.

On timeout, a custodian shutdown closes everything opened. A test server that accepts and never replies verifies that the sockets really close. Commit `4d24baf`.

## Phase 12: packaging and documentation

> the PR has been merged. Let's go back to main
>
> how does racket package libraries?
>
> create a branch and prepare for packaging and add some documentation

**What was built:**
- A single-collection package (`robotraconteur/info.rkt`), installed with `?path=robotraconteur` so the tests and examples stay outside it.
- A Scribble manual documenting every export.
- Tests switched to `(require robotraconteur)`, plus a stage that builds the package and its docs and runs Racket's dependency checker.

**Bug found by this change:** compiling the package with `raco setup` exposed a use-after-free in the TLS code. Each TLS context got its own C callback, and the FFI kept only the newest one alive. It was reproduced deterministically, then traced to the cause. The fix is in its own commit (`c1e3f82`), with a regression test that crashes the old code.

> At the very beginning of the documentation and readme state that this is an AI generation experiment and credit claude
>
> will the documentation show on the racket site when I register it?
>
> ok add my logo to the reademe as in other projects
>
> remove the (experimental) from the title
>
> good push and create a link to open the pr
>
> create a PR link that fills title and description
>
> PR 2

**Decisions:**
- **The AI note:** a sentence the first draft added on its own ("not part of the official Robot Raconteur project") was removed, because that's the owner's call.
- **The logo** was copied from the identical file used in the user's other repositories.

## Phase 13: standard device examples

> I need to switch to a different computer for this task, but I want to implement some of the standard device examples from core
>
> PR 2 merged
>
> We may not need to move computers. I have the 2ur5e training simulator scene running on `<other ip>`. You have permission to connect to the RR simulator on the published ports in the readme
>
> I cloned the sim into `<sources>/robotraconteur_training_sim` so you don't have to guess

**Decisions:**
- **Scoped to the permission given:** only the six ports in the simulator README's 2ur5e table, by direct URL, with no scanning or discovery. The first contact was a read-only probe of types and state.
- **Movement verified by sampling, not just exit codes:** the robot's joints were read while each example ran. Joint 0 followed the expected sine wave, and the trajectory example ended at its target.
- **Camera colors checked visually:** a raw frame converted by the new code was compared with the camera's own JPEG.
- **No OpenCV in Racket:** frames are saved as PNG by default, and `--show` opens a `racket/gui` window.

**Bugs found and fixed:**
- **The window hang:** the GUI loop blocked event handling, and an open window keeps a `racket/gui` program alive.
- **The test runner hang:** Racket 8.10 never reaps a GNU `timeout` child, which hung `system*`. Time limits now come from Racket itself.

**Testing:** a Python loopback camera serves frames colored in thirds, which catches swapped color channels.

> how do I run this myself without podman against the different ip address?
>
> I get a segfault trying to show the camera gui how do I capture to file
>
> saving to file works
>
> the crash is probably just this vm image. Can you create a discovery reynard example?

## Phase 14: discovery examples and Quick Start

**Discovery examples:** ports of the core's three Reynard discovery examples.

**Decision:** they were *not* run on the real LAN, because that would send multicast to every device on the user's network, beyond the permission given. They were tested in the namespace setup, with Reynard as a node there.

> commit changes
>
> add a quickstart to the readme similar to core
>
> we don't need the server side python code or in the quickstart. We can just use reynard for the target device
>
> commit, push, create PR description link
>
> PR 3

**Quick Start:** the first version reused the core's Python quick start service. After the user's correction it targets Reynard directly. Before committing, the client was run against Reynard and its position was read back.

**Flaky test fixed:** a full test run showed that the ServiceTest pipes test assumed acknowledgements arrive in order. The fix waits for the right one among any that arrive, which is still stricter than the Python original. It was pushed to the PR (`bd692f0`).

## Phase 15: publishing

> I am ready to add this to racket website but I lost the instructions in the history

**What was done:**
- **Registration steps** were given.

> This was an experiment, so generate a log of my prompts, the generation process, and your decision making in an md file

## Bugs found during the work

| Where | Bug | How it was found |
|---|---|---|
| This library | TLS verify callback use-after-free with more than one `rrs+tcp` context | Compiling the package differently changed GC timing; reproduced, then a regression test |
| This library | Connect could hang about 127 s, or forever on a silent server | User question about the TCP timeout |
| This library | Zoneless link-local URLs failed | User question about zone IDs |
| This library | Camera window hung; program never exited | Running `--show` under Xvfb |
| Tests | ServiceTest pipes test assumed ack order | A full run failed intermittently |
| Tests | `system*` hung on GNU `timeout` children (Racket 8.10) | A stalled run; `ps` showed an unreaped child |
| Core (reported upstream) | `user_state_dir` reads `ROBOTRACONTEUR_USER_CONFIG_DIR` | Reading `NodeDirectories.cpp` while building the TLS tests |
| Core Python test | `TestMonitorLock` can never fail | Porting it |

## Mistakes and corrections

- **Package site sign-in:** registration was first described as using GitHub sign-in. That was wrong; the site uses its own email-based accounts. It was corrected when the instructions were repeated.
- **Quick Start:** the first version included a Python service the user didn't want, and was rewritten around Reynard.
- **Flaky test:** the pipes test written during the port was flaky; see above.
- **CI watcher:** a background CI watcher looked runs up by the local commit and broke when branches changed. Later watchers used the run ID.
- **Two hung test runs:** the GUI loop and the `timeout` reaping. Each was stopped, its leftover container cleaned up, and the cause fixed before rerunning.
- **The AI note:** the first draft added an unrequested sentence, which was removed.

## How claims were checked

- **Compare against the reference implementation first:** the Python client or C++ core was run on a new test setup before the Racket code was judged against it (TLS chain, discovery).
- **Mutation checks:** for security and robustness code (certificate rules, timeouts, zone racing), each protection was removed on a scratch copy to confirm the matching test fails.
- **Read state back instead of trusting exit codes:** robot joints sampled during motion, camera colors inspected, Reynard's position read after the quick start.
- **Full offline suite before each push, and CI on each pull request.**

## Boundaries kept

- **Files:** nothing outside the workspace was modified. Reference checkouts were mounted read-only. One `rm -rf` inside a container script was blocked by a safety check and wasn't needed; the work continued without it.
- **Network:** apart from GitHub, the Racket package site (to check the package page) and package installs during image builds, only the two endpoints the user allowed were contacted.
- **Credentials:** the GitHub token was used per command and never stored.
- **Outward-facing actions:** pushes and pull requests happened only when asked. Before the first push to the public repository, the user was told what would become public.
- **Containers:** leftover containers from stopped runs were stopped. Two unrelated containers on the machine were identified and left alone.

## Commits

```
06e21ca Initial Racket Robot Raconteur client
969fe66 Add rr+ws WebSocket transport
c2ae56d Add interop tests with Reynard and a loopback AbstractRobot
7fd056a Add C++ toolchain and script to build the RR C++ test server
fcf819f Add test vector blob reader
594b926 robdef: support line continuations; add rr-enum-values
da36bf5 Add FFI harness for the in-process C++ test server
a78c82f Expose full remote error details
9abc610 Refresh objref types and handle ServicePathReleased
debb2d8 Add object locks and monitor locks
f45282a Add rr-generator-abort
d2e39b1 Rework wire connection API
c3a7d33 test-robot: bound trajectory end tolerance by the sampling step
c86ce72 Pipes: acknowledgements, listeners and early packets
da9a374 Port ServiceTestClient3 (TestService5) to Racket
fb5d1d0 Port ServiceTestClient (TestService1) to Racket
7936e07 Support multidim pod and namedarray fields; expose element packing
1464cc6 Port ServiceTestClient2 (TestService3) to Racket
ea2ab7a Run the ServiceTest ports in run_tests.sh; document the new API
ffcaaa8 Add rr+wss (WebSocket over standard TLS)
ac9a293 Add rrs+tcp (Robot Raconteur node TLS)
1981af6 Test rrs+tcp against secure services with a test PKI
a6450f8 Add Apache 2.0 license and GitHub Actions CI
bc4bc2e Add node and service discovery (IPv6 link-local multicast)
0c47d53 Test discovery on a tap interface inside the container
a51227e Connect to link-local IPv6 addresses without a zone
4d24baf Time out connects after 5 s (TCP) and 10 s (whole connect)
a8abe81 Merge pull request #1 from johnwason/discovery
c1e3f82 Fix a use-after-free of the TLS verify callback
8fe6d9c Package the library and add a Scribble manual
77e353f State that this is an AI generation experiment, crediting Claude
0144688 Add the Robot Raconteur logo header to the README
5ee04ab Drop "(experimental)" from the README title
da8a40b Merge pull request #2 from johnwason/packaging
c55e07a Add racket/draw and racket/gui libraries to the dev image
f13943c Port the standard device robot examples
ed56ef6 Port the standard device camera examples
2b1a2eb Test the standard device examples against loopback devices
ca5830b Port the Reynard discovery examples
b24575e Test the discovery examples on the tap interfaces
7d30db4 Add a Quick Start to the README, using Reynard the Robot
bd692f0 Fix a flaky ack check in the ServiceTest pipes test
c00941b Merge pull request #3 from johnwason/device-examples
```
