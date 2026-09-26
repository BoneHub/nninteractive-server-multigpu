# nnInteractive server on multiple GPUs

Run the official [nnInteractive](https://github.com/MIC-DKFZ/nnInteractive) server on a
machine with several NVIDIA GPUs, so that all users connect to **one port with one API key**.

One nnInteractive server container uses one GPU, even when it is started with
`--gpus all`. This project runs one server container per GPU and puts an nginx reverse
proxy in front of them. There are no scripts: you edit two config files by hand and run
`docker compose up -d`, on Linux or on Windows (Docker Desktop with the WSL2 backend).

```text
                                  +--> nn0: nnInteractive server on GPU 0
users --> port 1527 --> proxy ----+
          (one API key) (nginx)   +--> nn1: nnInteractive server on GPU 1
```

| File | Purpose |
|---|---|
| `compose.yaml` | One service per GPU (`nn0`, `nn1`, ...) plus the `proxy`. Preconfigured for GPUs 0 and 1. |
| `nginx.conf` | Proxy configuration. Lists the same GPU services. |
| `.env.example` | Settings template. Copy it to `.env` and set the API key. |

## How it works

- Each GPU service runs the official image `ghcr.io/mic-dkfz/nninteractive-server`,
  pinned to one GPU. These containers publish no ports; only the proxy can reach them.
- The proxy is the only thing users connect to (port 1527 by default).
- A user's session (uploaded image, prompts, segmentation) lives in the memory of the GPU
  container that created it, so every request from that user must reach the same
  container. nginx picks the container from the user's IP address
  (`hash $remote_addr consistent`): a user always lands on the same GPU, and when you add
  or remove a GPU, most users keep theirs.
- All GPU containers use the same API key from `.env`.

## Requirements

- NVIDIA GPUs with a recent driver (the server image uses CUDA 12.4).
- Docker Compose v2.17 or newer (check with `docker compose version`).
- **Linux:** Docker Engine and the
  [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),
  configured for Docker (`sudo nvidia-ctk runtime configure --runtime=docker`, then
  restart Docker).
- **Windows:** [Docker Desktop with GPU support](https://docs.docker.com/desktop/features/gpu/)
  (WSL2 backend). Read the [Windows notes](#windows-notes) first: two Docker Desktop
  limitations affect this setup.
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

   Open `.env` and set `NN_INTERACTIVE_API_KEY` to a long random value of letters and
   digits, for example the output of `openssl rand -hex 32`.

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

6. Check the proxy: on the server, open <http://127.0.0.1:1527/healthz>. It shows
   `{"ok":true}`.

## Connect a client

Give your users:

- **Server URL:** `http://<server name or IP>:1527`
- **API key:** the value of `NN_INTERACTIVE_API_KEY`

Clients need no changes: to them the proxy is one ordinary nnInteractive server. The
upstream [README](https://github.com/MIC-DKFZ/nnInteractive) and
[SERVER_CLIENT.md](https://github.com/MIC-DKFZ/nnInteractive/blob/master/SERVER_CLIENT.md)
describe the clients that support the server. From Python:

```python
from nnInteractive.inference.remote import nnInteractiveRemoteInferenceSession

session = nnInteractiveRemoteInferenceSession(
    server_url="http://gpu-server:1527",
    api_key="<the API key>",
)
```

## Choose the GPUs

GPU numbers are the ones `nvidia-smi -L` shows. Each GPU needs a service `nn<number>` in
`compose.yaml` and a `server` line with the same name in `nginx.conf`.

To add a GPU, for example GPU 2:

1. In `compose.yaml`, copy the `nn1` block, rename it to `nn2` and change `device_ids`:

   ```yaml
     nn2:
       <<: *nninteractive
       deploy:
         resources:
           reservations:
             devices:
               - driver: nvidia
                 device_ids: ["2"]
                 capabilities: [gpu]
   ```

2. In `compose.yaml`, add `nn2` to `depends_on` of the `proxy` service:

   ```yaml
       depends_on:
         nn0: { condition: service_started, restart: true }
         nn1: { condition: service_started, restart: true }
         nn2: { condition: service_started, restart: true }
   ```

3. In `nginx.conf`, add a line to the `upstream` block:

   ```nginx
           server nn2:1527;
   ```

4. Apply the change. `up -d` starts the new container. The proxy reads `nginx.conf` only
   when it starts, so restart it:

   ```
   docker compose up -d
   docker compose restart proxy
   ```

Some users now move to the new GPU (about one in three when going from two to three
GPUs); their open session ends and their client has to reconnect. All other users keep
their GPU.

To remove a GPU, delete it in the same three places and run:

```
docker compose up -d --remove-orphans
docker compose restart proxy
```

## Settings

The settings live in `.env`; changes take effect with `docker compose up -d`.

| Variable | Default | Meaning |
|---|---|---|
| `NN_INTERACTIVE_API_KEY` | none, required | The API key all users enter. Compose refuses to start without it. |
| `PUBLIC_PORT` | `1527` | Port users connect to. `127.0.0.1:1527` accepts connections from this machine only. |
| `NN_IMAGE` | `ghcr.io/mic-dkfz/nninteractive-server:latest` | Server image. Pin a version tag for reproducible deployments; the tags are listed in the upstream [DOCKER.md](https://github.com/MIC-DKFZ/nnInteractive/blob/master/nnInteractive/inference/server/DOCKER.md). |

### Server options

Options for the nnInteractive server go on the `command:` line in the shared block
(`x-nninteractive`) at the top of `compose.yaml`. Remove the `#` in front of it. The
options apply to every GPU container:

```yaml
  command: ["--max-sessions", "4"]
```

- `--max-sessions`: how many users one GPU container serves at the same time (default 3).
  The next user gets "server is at capacity". Predictions on one GPU run one after
  another, so more users per GPU means more waiting and more memory; upstream recommends
  adding GPUs over raising this number.
- `--idle-timeout-seconds`: close a user's session after this much inactivity
  (default 600).

`docker compose run --rm nn0 --help` lists all options.

## Everyday commands

Run them in the project folder.

| Task | Command |
|---|---|
| Show status | `docker compose ps` |
| Follow the logs | `docker compose logs -f` (one service: `docker compose logs -f nn1`) |
| Update the server image | `docker compose pull`, then `docker compose up -d` |
| Stop everything | `docker compose down` |
| Start again | `docker compose up -d` |

- Updating the image, changing the API key or restarting a GPU container ends the open
  sessions on that container. Users reconnect in their client.
- To change the API key, edit `.env`, run `docker compose up -d` and give users the new key.
- The containers restart by themselves after a crash or a reboot, as long as Docker
  starts at boot (Docker Desktop: turn on "Start Docker Desktop when you sign in").

To see which user is on which GPU, look at the proxy log. It shows every request as
`client address -> container address`:

```
docker compose logs proxy
```

This lists the address of each container:

```
docker inspect -f "{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" $(docker compose ps -q)
```

## How users are spread over the GPUs

Users are assigned to GPUs by IP address, not by load. This keeps sessions working
without any change to the clients, but:

- Users who share an IP address (same computer, NAT router, VPN gateway, remote desktop
  server) always share a GPU.
- The spread is roughly even but not balanced: one GPU can be full while another is idle.
  A user sent to a full container gets "server is at capacity", even if another GPU is
  free. Raise `--max-sessions` if memory allows, or add GPUs.
- If a GPU container is down, its users are sent to another one within a few seconds,
  and back when it returns. Each move ends the user's open session.
- nginx has to see the users' real IP addresses. Docker Engine on Linux passes them
  through for IPv4 connections from other machines. Connections from the server itself,
  IPv6 connections, and every connection on Docker Desktop (see
  [Windows notes](#windows-notes)) can instead arrive with one internal Docker address.
  Check `docker compose logs proxy`: if every line starts with the same address (such as
  `172.18.0.1`), all users are on one GPU.

## Security

- The API key is the only access control. Anyone who has it and can reach the port can
  use the GPUs.
- Traffic is plain HTTP, so the key and the images cross the network unencrypted. Run
  the server on a trusted network or VPN, or turn on HTTPS (below).
- Only the proxy port is published; the GPU containers are reachable only on the
  internal Docker network.
- Keep `.env` private. Git ignores it.

### Optional: HTTPS

nginx can encrypt the connections. Put the certificate (full chain) and its private key
in a `certs` folder next to `compose.yaml` (git ignores it), then:

1. In `compose.yaml`, add a volume to the `proxy` service:

   ```yaml
       volumes:
         - ./nginx.conf:/etc/nginx/nginx.conf:ro
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

The stack runs on Docker Desktop with the WSL2 backend, but two Docker Desktop
limitations affect it. Neither applies on Linux.

**1. Each GPU container may see all GPUs.** NVIDIA documents that under WSL2 a container
cannot be limited to chosen GPUs
([CUDA on WSL, known limitations](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)).
`device_ids` then has no effect, and every GPU container computes on the first GPU.
Check after starting:

```
docker compose exec nn1 nvidia-smi -L
```

If this lists more than one GPU, give every GPU service a `CUDA_VISIBLE_DEVICES` with
its own GPU number (the same number as in `device_ids`). For example, `nn1` becomes:

```yaml
  nn1:
    <<: *nninteractive
    environment:
      <<: *nninteractive-env
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

**2. nginx cannot see the users' IP addresses.** Docker Desktop relays published ports
through its own process, so nginx sees every user with the same internal address, for
example `172.19.0.1`. All users then land on the same GPU container while the other GPUs
stay idle. Check with `docker compose logs proxy`. No configuration change fixes this; to
spread users over the GPUs, run the stack on Linux.

If <http://localhost:1527> does not answer on the Windows machine itself, use
<http://127.0.0.1:1527>.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `required variable NN_INTERACTIVE_API_KEY is missing a value` | `.env` is missing, not next to `compose.yaml`, or the key in it is empty. |
| `could not select device driver "nvidia" with capabilities: [[gpu]]` | Docker cannot use the GPUs. Linux: install and configure the NVIDIA Container Toolkit. Windows: turn on GPU support in Docker Desktop and update the NVIDIA driver. |
| `nvidia-container-cli: device error: 1: unknown device` | `compose.yaml` uses a GPU number that does not exist. Compare with `nvidia-smi -L`. |
| The proxy keeps restarting and its log says `host not found in upstream "nn2:1527"` | `nginx.conf` lists a service that is not in `compose.yaml` or not running. Make both files list the same GPUs, then run `docker compose restart proxy`. |
| `502 Bad Gateway` | The GPU container is still starting (wait for `serving on` in its log) or has crashed (`docker compose logs nn0`). If it restarted by itself and the 502s continue, run `docker compose restart proxy`. |
| `401`, "Invalid bearer token" | The client uses a different API key than `.env`. |
| `503`, "server is at capacity" | The user's GPU container is full; see [How users are spread over the GPUs](#how-users-are-spread-over-the-gpus). |
| `410`, "lease expired or unknown", "session expired" | The session was closed after inactivity, or the user was moved to another container (container restart, GPU added or removed, the user's IP address changed). Reconnect in the client. |
| A new GPU gets no users | `nginx.conf` was not updated, or the proxy was not restarted. |

## License

This repository is licensed under the Apache License 2.0, see [LICENSE](LICENSE).

nnInteractive is developed by [MIC-DKFZ](https://github.com/MIC-DKFZ); this repository
only runs their official server image. The nnInteractive code is Apache-2.0, but the
model weights in the official server image are licensed CC BY-NC-SA 4.0: **non-commercial
use only**. If you use nnInteractive in research, cite it as described in the
[nnInteractive README](https://github.com/MIC-DKFZ/nnInteractive).
