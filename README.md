# nnInteractive server on multiple GPUs

Run the official [nnInteractive](https://github.com/MIC-DKFZ/nnInteractive) server on a
machine with several NVIDIA GPUs. All users connect to **one port**, each with **their own
API key**, and the key decides which GPU serves the user.

One nnInteractive server container uses one GPU, even when it is started with
`--gpus all`. This project runs one server container per GPU and puts an nginx reverse
proxy in front of them. You list the users' keys per GPU in `.env` and run
`docker compose up -d`, on Linux or on Windows (Docker Desktop with the WSL2 backend).

```text
user with key A --+                                  +--> nn0: server on GPU 0   GPU0_USER_KEYS=A,B
user with key B --+                                  |
                  +--> port 1527 --> proxy (nginx) --+
user with key C --+                                  |
user with key D --+                                  +--> nn1: server on GPU 1   GPU1_USER_KEYS=C,D
```

| File | Purpose |
|---|---|
| `.env.example` | Settings template with the users' keys per GPU. Copy it to `.env` and fill in the keys. |
| `compose.yaml` | One service per GPU (`nn0`, `nn1`, ...) plus the `proxy`. Preconfigured for GPUs 0 and 1. |
| `nginx.conf` | Proxy configuration. |
| `proxy-start.sh` | Runs when the proxy starts: checks the keys in `.env` and hands them to nginx. |
| `gpu-start.sh` | Runs when a GPU container starts: sets its `--max-sessions` to its number of users. |

You never run the two scripts yourself.

## How it works

- Each GPU service runs the official image `ghcr.io/mic-dkfz/nninteractive-server`,
  pinned to one GPU. These containers publish no ports; only the proxy can reach them.
- The proxy is the only thing users connect to (port 1527 by default).
- `.env` gives every user a key and a GPU: `GPU0_USER_KEYS` lists the keys of the users of
  GPU 0, `GPU1_USER_KEYS` those of GPU 1, and so on.
- The client sends the key with every request. The proxy passes each request to the GPU
  container of its key and answers `401` to an unknown key. A user's session (uploaded
  image, prompts, segmentation) lives in the memory of that container, and since the user
  always reaches the same container, the session keeps working. The IP address plays no
  part: users who share one (NAT router, VPN, remote desktop server, Docker Desktop) still
  reach their own GPU.
- The proxy replaces the user's key with `INTERNAL_API_KEY` before passing a request on.
  The GPU containers accept only that key; users never see it.
- A GPU container serves one session per user at a time: its `--max-sessions` is the
  number of keys in its line in `.env`.

## Requirements

- NVIDIA GPUs with a recent driver (the server image uses CUDA 12.4).
- Docker Compose v2.17 or newer (check with `docker compose version`).
- **Linux:** Docker Engine and the
  [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),
  configured for Docker (`sudo nvidia-ctk runtime configure --runtime=docker`, then
  restart Docker).
- **Windows:** [Docker Desktop with GPU support](https://docs.docker.com/desktop/features/gpu/)
  (WSL2 backend). Read the [Windows notes](#windows-notes) first: a Docker Desktop
  limitation can affect this setup.
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

   Open `.env` and fill in the keys: `INTERNAL_API_KEY`, and the keys of the users of GPU 0
   and GPU 1, separated by commas. Make every key with `openssl rand -hex 16`, a new value
   for each:

   ```
   INTERNAL_API_KEY=<key>
   # GPU 0: Alice, Bob
   GPU0_USER_KEYS=<Alice's key>,<Bob's key>
   # GPU 1: Carol, Dave
   GPU1_USER_KEYS=<Carol's key>,<Dave's key>
   ```

   The comment lines are optional; they help to remember whose key is whose.

3. Check your GPU numbers with `nvidia-smi -L`. `compose.yaml` uses GPUs 0 and 1; to use
   other GPUs, first [choose the GPUs](#choose-the-gpus).

4. Start everything:

   ```
   docker compose up -d
   ```

5. Wait until each GPU container is ready. The first start downloads the image and
   compiles the model, which can take several minutes. A container is ready when its log
   shows `serving on http://0.0.0.0:1527`:

   ```
   docker compose logs -f nn0 nn1
   ```

   Ctrl+C stops following the logs; the servers keep running.

6. Check the proxy. `docker compose logs proxy` shows how many user keys each GPU has.
   Then send a request with one user's key (in Windows PowerShell, type `curl.exe`
   instead of `curl`):

   ```
   curl -H "Authorization: Bearer <a user's key>" http://127.0.0.1:1527/healthz
   ```

   It shows `{"ok":true}` when that user's GPU container is ready. Without a key,
   `/healthz` only shows that the proxy is running.

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

## Manage users

The users of a GPU are the keys in its line in `.env`.

- **Add a user:** make a new key (`openssl rand -hex 16`) and add it to the line of the
  GPU the user should work on.
- **Remove a user:** delete their key. The proxy then rejects it.
- **Move a user to another GPU:** move their key to that GPU's line.
- **Give a user a new key:** replace their old key.

Then apply the change:

```
docker compose up -d
```

This restarts the proxy, and every GPU container whose line changed, because its
`--max-sessions` changes with it. A restarted GPU container ends its users' open sessions
and needs a few minutes to load the model again; the other GPU containers keep running,
and so do their users' sessions. Requests that are running while the proxy restarts
fail and have to be repeated.

## Choose the GPUs

GPU numbers are the ones `nvidia-smi -L` shows. Each GPU needs a service `nn<number>` in
`compose.yaml` and a line `GPU<number>_USER_KEYS` in `.env`.

To add a GPU, for example GPU 2:

1. In `compose.yaml`, copy the `nn1` block, rename it to `nn2` and change its other two
   1s to 2:

   ```yaml
     nn2:
       <<: *nninteractive
       environment:
         <<: *nninteractive-env
         USER_KEYS: ${GPU2_USER_KEYS:?Set GPU2_USER_KEYS in .env}
       deploy:
         resources:
           reservations:
             devices:
               - driver: nvidia
                 device_ids: ["2"]
                 capabilities: [gpu]
   ```

2. In `.env`, add a line with the keys of the users of GPU 2 (new users, or keys moved
   from another GPU's line):

   ```
   GPU2_USER_KEYS=<key>,<key>
   ```

3. Apply the change:

   ```
   docker compose up -d
   ```

To remove a GPU, delete its block in `compose.yaml` and its line in `.env`, and move the
keys of its users to another GPU's line (or they can no longer connect). Then run:

```
docker compose up -d --remove-orphans
```

## Settings

The settings live in `.env`; changes take effect with `docker compose up -d`.

| Variable | Default | Meaning |
|---|---|---|
| `INTERNAL_API_KEY` | none, required | The key the proxy uses for the GPU containers. Users never see or need it. |
| `GPU<number>_USER_KEYS` | none, required for each GPU service | The keys of the users of that GPU, separated by commas. Also that GPU's `--max-sessions`: one session per key. |
| `PUBLIC_PORT` | `1527` | Port users connect to. `127.0.0.1:1527` accepts connections from this machine only. |
| `NN_IMAGE` | `ghcr.io/mic-dkfz/nninteractive-server:latest` | Server image. Pin a version tag for reproducible deployments; the tags are listed in the upstream [DOCKER.md](https://github.com/MIC-DKFZ/nnInteractive/blob/master/nnInteractive/inference/server/DOCKER.md). |

Every key is at most 128 letters and digits, and no two keys are the same (upper and lower
case count as the same). The proxy does not start while a key breaks these rules; see
[Troubleshooting](#troubleshooting).

> **Warning:** there is no minimum length, but the key is the only thing that keeps others
> off the GPUs. A short key such as `alice` or `1234` is easy to guess for anyone who can
> reach `PUBLIC_PORT`. Use short keys only when the port is reachable from trusted machines
> alone (e.g. `127.0.0.1:1527`, a VPN or a firewalled lab network). Otherwise make every
> key with `openssl rand -hex 16`.

### Server options

Options for the nnInteractive server go on the `command:` line in the shared block
(`x-nninteractive`) at the top of `compose.yaml`. Remove the `#` in front of it. The
options apply to every GPU container:

```yaml
  command: ["--idle-timeout-seconds", "1800"]
```

- `--idle-timeout-seconds`: close a user's session after this much inactivity
  (default 600).
- `--max-sessions`: how many sessions one GPU container serves at the same time.
  `gpu-start.sh` sets it to the number of keys of the GPU; a `--max-sessions` on the
  `command:` line replaces that number. For example, to let each of the two users of
  GPU 0 open a second session, add `command: ["--max-sessions", "4"]` to the `nn0`
  service. A `command:` in a service replaces the shared one, so repeat any shared
  options there.

`docker compose run --rm nn0 --help` lists all options.

## Sessions

- Each user has one session slot on their GPU. A user who opens a second session at the
  same time (a second viewer window, or a script next to the viewer) takes the slot of
  another user of that GPU, who then gets "server is at capacity".
- A session ends when the client closes it, after 10 minutes without user actions
  (`--idle-timeout-seconds`), or about a minute after the client stopped (crash, lost
  network). Until then it keeps its slot: after a crash, a user may have to wait up to a
  minute before they can connect again, if the GPU's other users are all connected.
- Predictions on one GPU run one after another, so users of the same GPU wait for each
  other. Put users who work at the same time on different GPUs.
- If a GPU container is down, its users get `502` until Docker has restarted it and the
  model is loaded; users of the other GPUs are not affected. Users are not moved to
  another GPU: there they would take the slots of that GPU's users.

## Everyday commands

Run them in the project folder.

| Task | Command |
|---|---|
| Show status | `docker compose ps` |
| Follow the logs | `docker compose logs -f` (one service: `docker compose logs -f nn1`) |
| Add, remove or move a user | Edit `.env`, then `docker compose up -d` (see [Manage users](#manage-users)) |
| Update the server image | `docker compose pull`, then `docker compose up -d` |
| Stop everything | `docker compose down` |
| Start again | `docker compose up -d` |

- Updating the image, changing `INTERNAL_API_KEY` or restarting a GPU container ends the
  open sessions on that container. Users reconnect in their client.
- The containers restart by themselves after a crash or a reboot, as long as Docker
  starts at boot (Docker Desktop: turn on "Start Docker Desktop when you sign in").

To see who works on which GPU, look at the proxy log:

```
docker compose logs proxy
```

It shows every request with the client address, the user and the address of the GPU
container that served it:

```
172.18.0.1 gpu0-user2 -> 172.18.0.3:1527 [27/Sep/2026:10:15:02 +0000] "POST /add_point_interaction HTTP/1.1" 200 5123 0.412s
```

`gpu0-user2` is the second key in `GPU0_USER_KEYS`. A request with an unknown key shows
`- -> -` and status `401`.

## Security

- Every user has their own key. The proxy rejects requests with any other key (`401`)
  before they reach a GPU container. To lock a user out, delete their key from `.env`
  and run `docker compose up -d`.
- The GPU containers accept only `INTERNAL_API_KEY`, which only the proxy sends. They
  publish no ports, so only the internal Docker network can reach them.
- Traffic is plain HTTP, so the keys and the images cross the network unencrypted. Run
  the server on a trusted network or VPN, or turn on HTTPS (below).
- `/healthz` answers without a key, as on the nnInteractive server itself. It shows only
  that the service is running.
- Keep `.env` private. Git ignores it.

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

The stack runs on Docker Desktop with the WSL2 backend. One Docker Desktop limitation
can require a change; it does not apply on Linux.

**Each GPU container may see all GPUs.** NVIDIA documents that under WSL2 a container
cannot be limited to chosen GPUs
([CUDA on WSL, known limitations](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)).
`device_ids` then has no effect, and every GPU container computes on the first GPU.
Check after starting:

```
docker compose exec nn1 nvidia-smi -L
```

If this lists more than one GPU, add `CUDA_VISIBLE_DEVICES` with its own GPU number (the
same number as in `device_ids`) to the `environment:` of every GPU service. For example,
`nn1` becomes:

```yaml
  nn1:
    <<: *nninteractive
    environment:
      <<: *nninteractive-env
      USER_KEYS: ${GPU1_USER_KEYS:?Set GPU1_USER_KEYS in .env}
      CUDA_VISIBLE_DEVICES: "1"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["1"]
              capabilities: [gpu]
```

Then run `docker compose up -d`. `compose.yaml` already numbers GPUs the way
`nvidia-smi` does (`CUDA_DEVICE_ORDER`). `nvidia-smi -L` inside a container keeps
listing all GPUs, so to confirm the fix run `nvidia-smi` on Windows: every GPU now shows
memory in use. Only make this change where the check lists all GPUs. On Linux each
container sees just its own GPU (as number 0), and `CUDA_VISIBLE_DEVICES: "1"` would
hide it.

The proxy log shows the same client address for every user, for example `172.19.0.1`:
Docker Desktop relays published ports through its own process. This does not matter:
the proxy picks the GPU by key, not by address.

If <http://localhost:1527> does not answer on the Windows machine itself, use
<http://127.0.0.1:1527>.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `required variable INTERNAL_API_KEY is missing a value` (or `GPU0_USER_KEYS`, ...) | `.env` is missing, not next to `compose.yaml`, or that line in it is empty. Every GPU service in `compose.yaml` needs its `GPU<number>_USER_KEYS` line. |
| The proxy keeps restarting, and `docker compose logs proxy` shows a `proxy-start.sh:` message | A key in `.env` breaks the rules (see [Settings](#settings)); the message names the key. Fix `.env`, then run `docker compose up -d`. |
| `could not select device driver "nvidia" with capabilities: [[gpu]]` | Docker cannot use the GPUs. Linux: install and configure the NVIDIA Container Toolkit. Windows: turn on GPU support in Docker Desktop and update the NVIDIA driver. |
| `nvidia-container-cli: device error: 1: unknown device` | `compose.yaml` uses a GPU number that does not exist. Compare with `nvidia-smi -L`. |
| `401`, "Missing bearer token" | The client sends no key. Enter the user's key in the client. |
| `401`, "Invalid bearer token" | The key is not in `.env` (a typo?), or `.env` was changed without running `docker compose up -d` afterwards. |
| `502 Bad Gateway` | The user's GPU container is still starting (wait for `serving on` in its log) or has crashed (`docker compose logs nn0`). If the proxy log says `nn2 could not be resolved`, `.env` has a `GPU2_USER_KEYS` line but `compose.yaml` has no running `nn2` service. |
| `503`, "server is at capacity" | All session slots of the user's GPU are taken; see [Sessions](#sessions). |
| `410`, "lease expired or unknown", "session expired" | The session was closed after inactivity, or the user's GPU container restarted (image update, the GPU's line in `.env` changed), or the user's key moved to another GPU. Reconnect in the client. |

## License

This repository is licensed under the Apache License 2.0, see [LICENSE](LICENSE).

nnInteractive is developed by [MIC-DKFZ](https://github.com/MIC-DKFZ); this repository
only runs their official server image. The nnInteractive code is Apache-2.0, but the
model weights in the official server image are licensed CC BY-NC-SA 4.0: **non-commercial
use only**. If you use nnInteractive in research, cite it as described in the
[nnInteractive README](https://github.com/MIC-DKFZ/nnInteractive).
