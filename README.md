# nnInteractive server on multiple GPUs

Run the official [nnInteractive](https://github.com/MIC-DKFZ/nnInteractive) server for
several users on a machine with several NVIDIA GPUs. All users connect to **one port**,
each with **their own API key**. Every user gets **their own server container** on the
GPU you choose for them, so one user's sessions never take another user's place.

This project runs one nnInteractive server container per user and puts an nginx reverse
proxy in front of them. You list the users' keys per GPU in `.env`, and two commands
create the containers, on Linux or on Windows (Docker Desktop with the WSL2 backend).

```text
key A --+                                  +--> gpu0-user1: server on GPU 0   GPU0_USER_KEYS=A,B
key B --+                                  +--> gpu0-user2: server on GPU 0
        +--> port 1527 --> proxy (nginx) --+
key C --+                                  +--> gpu1-user1: server on GPU 1   GPU1_USER_KEYS=C,D
key D --+                                  +--> gpu1-user2: server on GPU 1
```

| File | Purpose |
|---|---|
| `.env.example` | Settings template with the users' keys per GPU. Copy it to `.env` and fill in the keys. |
| `compose.yaml` | The `proxy`, and `nninteractive`: the template of every user's server container. |
| `compose.override.yaml` | Not in the repository: `docker compose run --rm configure` writes it from `.env`, with one service per user (`gpu0-user1`, ...). |
| `nginx.conf` | Proxy configuration. |
| `configure.sh` | Writes `compose.override.yaml` (run through `docker compose run --rm configure`). |
| `proxy-start.sh` | Runs when the proxy starts: checks the keys in `.env` and hands them to nginx. |
| `server-start.sh` | Runs when a user's container starts: selects the user's GPU and `--max-sessions`. |

You never run the three scripts yourself.

## How it works

- `.env` gives every user a key and a GPU: `GPU0_USER_KEYS` lists the keys of the users of
  GPU 0, `GPU1_USER_KEYS` those of GPU 1, and so on.
- `docker compose run --rm configure` writes `compose.override.yaml` with one service per
  key: `gpu0-user2` is the second key in `GPU0_USER_KEYS`. Each is a copy of the
  `nninteractive` service in `compose.yaml` and runs the official image
  `ghcr.io/mic-dkfz/nninteractive-server`.
- Every container sees all GPUs and computes on its user's GPU only: the server is started
  with `--device cuda:<number>`, with the GPUs numbered as `nvidia-smi -L` numbers them.
  The containers publish no ports; only the proxy can reach them.
- The proxy is the only thing users connect to (port 1527 by default). The client sends
  the key with every request; the proxy passes each request to the container of that key
  and answers `401` to an unknown key. A user's session (uploaded image, prompts,
  segmentation) lives in the memory of their container, and since the user always
  reaches the same container, the session keeps working. The IP address plays no part:
  users who share one (NAT router, VPN, remote desktop server, Docker Desktop) still reach
  their own container.
- The proxy replaces the user's key with `INTERNAL_API_KEY` before passing a request on.
  The server containers accept only that key; users never see it.
- Each container serves only its own user, with `MAX_SESSIONS_PER_USER` sessions at a time
  (default 1). A user who opens too many sessions is refused; the other users are not
  affected.

## Requirements

- NVIDIA GPUs with a recent driver (the server image uses CUDA 12.4), with enough memory
  for their users: every user's container holds its own copy of the model in GPU memory,
  plus the images of that user's sessions.
- Docker Compose v2.17 or newer (check with `docker compose version`).
- **Linux:** Docker Engine and the
  [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),
  configured for Docker (`sudo nvidia-ctk runtime configure --runtime=docker`, then
  restart Docker).
- **Windows:** [Docker Desktop with GPU support](https://docs.docker.com/desktop/features/gpu/)
  (WSL2 backend). See the [Windows notes](#windows-notes).
- Several GB of disk space for the server image.

Check that Docker can use your GPUs (this lists them):

```
docker run --rm --gpus all ubuntu nvidia-smi -L
```

## Quick start

1. Get the files:

   ```
   git clone https://github.com/BoneHub/nninteractive-server-multigpu.git
   cd nninteractive-server-multigpu
   ```

2. Create `.env` from the template (Windows: `copy .env.example .env`):

   ```
   cp .env.example .env
   ```

   Open `.env` and fill in the keys: `INTERNAL_API_KEY`, and for every GPU the keys of its
   users, separated by commas. The GPU numbers are the ones `nvidia-smi -L` shows; delete
   the line of a GPU without users. Make every key with `openssl rand -hex 16`, a new value
   for each:

   ```
   INTERNAL_API_KEY=<key>
   # GPU 0: Alice, Bob
   GPU0_USER_KEYS=<Alice's key>,<Bob's key>
   # GPU 1: Carol, Dave
   GPU1_USER_KEYS=<Carol's key>,<Dave's key>
   ```

   The comment lines are optional; they help to remember whose key is whose.

3. Create the users' containers from `.env`, and start everything:

   ```
   docker compose run --rm configure
   docker compose up -d --remove-orphans
   ```

4. Wait until the containers are ready. The first start downloads the image, then every
   container loads and compiles the model, which can take several minutes. A container
   is ready when its log shows `serving on http://0.0.0.0:1527`:

   ```
   docker compose logs -f
   ```

   Ctrl+C stops following the logs; the servers keep running. `docker compose ps` lists
   one container per user, plus the proxy.

5. Check the proxy. `docker compose logs proxy` shows how many user keys each GPU has.
   Then send a request with one user's key (in Windows PowerShell, type `curl.exe`
   instead of `curl`):

   ```
   curl -H "Authorization: Bearer <a user's key>" http://127.0.0.1:1527/healthz
   ```

   It shows `{"ok":true}` when that user's container is ready. Without a key, `/healthz`
   only shows that the proxy is running.

6. Check the GPUs: `nvidia-smi` (on the host) shows memory in use on every GPU that has
   users.

## Connect a client

Give each user:

- **Server URL:** `http://<server name or IP>:1527`
- **API key:** their own key from `.env`

Clients need no changes: to them the proxy is one ordinary nnInteractive server. The
upstream [README](https://github.com/MIC-DKFZ/nnInteractive) and
[SERVER_CLIENT.md](https://github.com/MIC-DKFZ/nnInteractive/blob/master/SERVER_CLIENT.md)
describe the clients that support the server. From Python:

```python
from nnInteractive.inference.remote import nnInteractiveRemoteInferenceSession

session = nnInteractiveRemoteInferenceSession(
    server_url="http://gpu-server:1527",
    api_key="<the user's key>",
)
```

## Manage users and GPUs

The users of a GPU are the keys in its line in `.env`.

- **Add a user:** make a new key (`openssl rand -hex 16`) and add it to the line of the
  GPU the user should work on.
- **Remove a user:** delete their key. The proxy then rejects it.
- **Move a user to another GPU:** move their key to that GPU's line.
- **Give a user a new key:** replace their old key.
- **Use another GPU:** add a line for it, e.g. `GPU2_USER_KEYS=<key>,<key>` (new users, or
  keys moved from another GPU's line).
- **Stop using a GPU:** delete its line, and move the keys of its users to another GPU's
  line (or they can no longer connect).

Then apply the change:

```
docker compose run --rm configure
docker compose up -d --remove-orphans
```

`configure` is needed only when keys or GPU lines were added or removed (not for a new
key in place of an old one, or other settings), but running it every time does no harm.
The proxy does not start while it is needed; see [Troubleshooting](#troubleshooting).

What restarts:

- The proxy. Requests that are running at that moment fail and have to be repeated.
- The container of a new user starts, which takes a few minutes; the container of a
  removed user stops.
- The containers are numbered by position in the line: after the key of `gpu0-user1` is
  deleted, the next key on the line is served by `gpu0-user1`. The users after a removed
  or moved key therefore change containers, and their open sessions end. Add new keys at
  the end of a line to leave the other users undisturbed.
- All other containers keep running, and so do their users' sessions.

## Settings

The settings live in `.env`; changes take effect with `docker compose up -d`.

| Variable | Default | Meaning |
|---|---|---|
| `INTERNAL_API_KEY` | none, required | The key the proxy uses for the server containers. Users never see or need it. |
| `GPU<number>_USER_KEYS` | at least one line, required | The keys of the users of that GPU, separated by commas. Every key gets its own server container on that GPU. After adding or removing keys or lines, run `docker compose run --rm configure` first. |
| `MAX_SESSIONS_PER_USER` | `1` | How many sessions each user can have open at the same time (`--max-sessions` of every user's container). |
| `PUBLIC_PORT` | `1527` | Port users connect to. `127.0.0.1:1527` accepts connections from this machine only. |
| `NN_IMAGE` | `ghcr.io/mic-dkfz/nninteractive-server:latest` | Server image. Pin a version tag for reproducible deployments; the tags are listed in the upstream [DOCKER.md](https://github.com/MIC-DKFZ/nnInteractive/blob/master/nnInteractive/inference/server/DOCKER.md). |

Changing `INTERNAL_API_KEY`, `MAX_SESSIONS_PER_USER` or `NN_IMAGE` restarts every user's
container, which ends all open sessions.

Every key is at most 128 letters and digits, and no two keys are the same (upper and lower
case count as the same). The proxy does not start while a key breaks these rules; see
[Troubleshooting](#troubleshooting).

> **Warning:** there is no minimum length, but the key is the only thing that keeps others
> off the GPUs. A short key such as `alice` or `1234` is easy to guess for anyone who can
> reach `PUBLIC_PORT`. Use short keys only when the port is reachable from trusted machines
> alone (e.g. `127.0.0.1:1527`, a VPN or a firewalled lab network). Otherwise make every
> key with `openssl rand -hex 16`.

### Server options

Options for the nnInteractive server go on the `command:` line of the `nninteractive`
service in `compose.yaml`. Remove the `#` in front of it. The options apply to every
user's container:

```yaml
    command: ["--idle-timeout-seconds", "1800"]
```

- `--idle-timeout-seconds`: close a session after this much inactivity (default 600).
- `--max-sessions` and `--device` are set by `server-start.sh`, from
  `MAX_SESSIONS_PER_USER` and the user's GPU. The same options on the `command:` line
  replace them for every container; use `MAX_SESSIONS_PER_USER` instead.

Then run `docker compose up -d`. `docker compose run --rm gpu0-user1 --help` lists all
options.

## Sessions

- Each user has `MAX_SESSIONS_PER_USER` session slots (default 1) in their own container. A
  user who opens more sessions at the same time (a second viewer window, or a script next
  to the viewer) gets "server is at capacity"; other users never do because of it.
- A session ends when the client closes it, after 10 minutes without user actions
  (`--idle-timeout-seconds`), or about a minute after the client stopped (crash, lost
  network). Until then it keeps its slot: after a crash, a user may have to wait up to a
  minute before they can connect again.
- Users of the same GPU share its compute and memory. Their predictions run at the same
  time and slow each other down, and each container keeps its own copy of the model and
  its sessions' images in GPU memory. If a GPU runs out of memory, predictions fail with
  CUDA out-of-memory errors in the container's log: put fewer users on that GPU, or lower
  `MAX_SESSIONS_PER_USER`. Put users who work at the same time on different GPUs.
- If a user's container is down, that user gets `502` until Docker has restarted it and
  the model is loaded; other users are not affected.

## Everyday commands

Run them in the project folder.

| Task | Command |
|---|---|
| Show status | `docker compose ps` |
| Follow the logs | `docker compose logs -f` (one container: `docker compose logs -f gpu0-user2`) |
| Add, remove or move a user | Edit `.env`, then `docker compose run --rm configure` and `docker compose up -d --remove-orphans` (see [Manage users and GPUs](#manage-users-and-gpus)) |
| Update the server image | `docker compose pull`, then `docker compose up -d` |
| Stop everything | `docker compose down` |
| Start again | `docker compose up -d` |

- Updating the image, changing `INTERNAL_API_KEY` or restarting a user's container ends
  the open sessions on that container. Users reconnect in their client.
- The containers restart by themselves after a crash or a reboot, as long as Docker
  starts at boot (Docker Desktop: turn on "Start Docker Desktop when you sign in").

To see who works when, look at the proxy log:

```
docker compose logs proxy
```

It shows every request with the client address, the user and the address of the
container that served it:

```
172.18.0.1 gpu0-user2 -> 172.18.0.3:1527 [27/Sep/2026:10:15:02 +0000] "POST /add_point_interaction HTTP/1.1" 200 5123 0.412s
```

`gpu0-user2` is the second key in `GPU0_USER_KEYS`, and also the name of that user's
container. A request with an unknown key shows `- -> -` and status `401`.

## Security

- Every user has their own key. The proxy rejects requests with any other key (`401`)
  before they reach a server container. To lock a user out, delete their key from `.env`
  and apply the change (see [Manage users and GPUs](#manage-users-and-gpus)).
- The server containers accept only `INTERNAL_API_KEY`, which only the proxy sends. They
  publish no ports, so only the internal Docker network can reach them.
- Traffic is plain HTTP, so the keys and the images cross the network unencrypted. Run
  the server on a trusted network or VPN, or turn on HTTPS (below).
- `/healthz` answers without a key, as on the nnInteractive server itself. It shows only
  that the service is running.
- Keep `.env` private. Git ignores it. `compose.override.yaml` holds no keys.

### Optional: HTTPS

nginx can encrypt the connections. Put the certificate (full chain) and its private key
in a `certs` folder next to `compose.yaml` (git ignores it), then:

1. In `compose.yaml`, add a volume to the `proxy` service:

   ```yaml
       volumes:
         - ./nginx.conf:/etc/nginx/nginx.conf:ro
         - ./proxy-start.sh:/proxy-start.sh:ro
         - ./certs:/etc/nginx/certs:ro
   ```

2. In `nginx.conf`, replace `listen 1527;` with:

   ```nginx
           listen 1527 ssl;
           ssl_certificate     /etc/nginx/certs/fullchain.pem;
           ssl_certificate_key /etc/nginx/certs/privkey.pem;
   ```

3. Run `docker compose up -d`. Users now connect to `https://<server name>:1527`. The
   certificate must be issued for that name and trusted by the users' computers.

## Windows notes

The stack runs unchanged on Docker Desktop with the WSL2 backend.

Under WSL2 a container cannot be limited to chosen GPUs
([CUDA on WSL, known limitations](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)).
That does not matter here: every container sees all GPUs on Linux too, and the server
selects its user's GPU itself (`--device cuda:<number>`). `compose.yaml` numbers the GPUs
the way `nvidia-smi` does (`CUDA_DEVICE_ORDER`), so the numbers in `.env` are the ones
`nvidia-smi -L` shows on Windows. `nvidia-smi` on Windows lists no container processes;
the memory in use on each GPU shows which GPUs are working.

The proxy log shows the same client address for every user, for example `172.19.0.1`:
Docker Desktop relays published ports through its own process. This does not matter:
the proxy picks the container by key, not by address.

If <http://localhost:1527> does not answer on the Windows machine itself, use
<http://127.0.0.1:1527>.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `required variable INTERNAL_API_KEY is missing a value` | `.env` is missing, not next to `compose.yaml`, or `INTERNAL_API_KEY` in it is empty. |
| The proxy keeps restarting, and `docker compose logs proxy` shows `the server containers do not match the keys in .env` | Keys or GPU lines were added to or removed from `.env` since `compose.override.yaml` was written (or it was never written). Run `docker compose run --rm configure`, then `docker compose up -d --remove-orphans`. |
| The proxy keeps restarting, and `docker compose logs proxy` shows another `proxy-start.sh:` message | A key in `.env` breaks the rules (see [Settings](#settings)); the message names the key. Fix `.env`, then run `docker compose up -d`. |
| `configure.sh: compose.override.yaml was not written by configure.sh` | You have your own `compose.override.yaml`. Move its settings to `compose.yaml`, delete it and run `configure` again. |
| `could not select device driver "nvidia" with capabilities: [[gpu]]` | Docker cannot use the GPUs. Linux: install and configure the NVIDIA Container Toolkit. Windows: turn on GPU support in Docker Desktop and update the NVIDIA driver. |
| A user's container keeps restarting, and its log shows `GPU 2 does not exist` (or a CUDA error `invalid device ordinal`) | `.env` has a line for a GPU number that does not exist. Compare with `nvidia-smi -L`, fix `.env`, then run `configure` and `docker compose up -d --remove-orphans`. |
| `401`, "Missing bearer token" | The client sends no key. Enter the user's key in the client. |
| `401`, "Invalid bearer token" | The key is not in `.env` (a typo?), or `.env` was changed without applying it afterwards. |
| `502 Bad Gateway` | The user's container is still starting (wait for `serving on` in its log, e.g. `docker compose logs gpu0-user1`) or has crashed. |
| `503`, "server is at capacity" | The user already has `MAX_SESSIONS_PER_USER` sessions open, perhaps one of a crashed client that has not expired yet; see [Sessions](#sessions). |
| `410`, "lease expired or unknown", "session expired" | The session was closed after inactivity, or the user's container restarted or changed (image update, `MAX_SESSIONS_PER_USER` changed, a key before theirs on the same line removed, their key moved to another GPU). Reconnect in the client. |
| `CUDA out of memory` in a container's log | Too many users or sessions on that GPU; see [Sessions](#sessions). |

## License

This repository is licensed under the Apache License 2.0, see [LICENSE](LICENSE).

nnInteractive is developed by [MIC-DKFZ](https://github.com/MIC-DKFZ); this repository
only runs their official server image. The nnInteractive code is Apache-2.0, but the
model weights in the official server image are licensed CC BY-NC-SA 4.0: **non-commercial
use only**. If you use nnInteractive in research, cite it as described in the
[nnInteractive README](https://github.com/MIC-DKFZ/nnInteractive).
