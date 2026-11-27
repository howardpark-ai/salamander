# The web UI on your own machine: ttyd, and HTTPS with a login in front

sala's web UI (sala-web, `web/README.md`) shows the sessions in a browser: a chat per session, a composer that types into a pane,
a Terminal tab and a Shell drawer. This page is how someone else installs it. Three user units make the web UI, and one proxy in front
of them is the login.

```
browser --HTTPS + login--> proxy (Caddy below) --unix socket--> sala-web     (the app, everything but /tty/)
                                              \--unix socket--> ttyd        (the Terminal tab and the Shell drawer, at /tty/)
```

| piece | where | what it is |
|---|---|---|
| `sala-web.socket`, `sala-web.service` | `web/contrib/` | the app, a Python (starlette, uvicorn) process on a unix socket, `$XDG_RUNTIME_DIR/sala-web/sala-web.sock` |
| `sala-web-ttyd.service` | `web/contrib/` | [ttyd](https://github.com/tsl0922/ttyd) on a unix socket, `$XDG_RUNTIME_DIR/sala-web-ttyd/ttyd.sock`, serving a tmux session in the browser under the path `/tty/` |
| `sala-web-ttyd-attach` | `web/contrib/` | the command ttyd runs per tab: `/tty/?arg=<session>` attaches that tmux session, and only an existing one |
| the proxy | this page | HTTPS and the login; not part of sala |

## The rule: nothing is reachable without a login

**Neither socket may be reachable from any machine or any other user without a login in front of it.** sala-web types into the Claude
panes and can start sessions; ttyd is a shell of your user in a browser tab. Neither has a login of its own, which is why both listen on
unix sockets only (mode 0600, in a 0700 directory), never on a TCP port: a loopback port would give the same access to every local user.

- Do not change them to listen on a TCP port, not even on `127.0.0.1`, and do not publish a port or a tunnel route that goes to one of
  the sockets without an authentication step ahead of it.
- The login must cover **both**: the app (`/`) and ttyd (`/tty/`). A proxy that protects only `/` leaves a shell open at `/tty/`.
  The app's `/terminal` page (the Shell drawer's *Open full size*, a full-window frame of the same `/tty/`) needs no route of its own: the
  proxy sends everything except `/tty` to the app, so the login that covers `/` covers it. Do not route it to ttyd.
- Serve it over HTTPS only. A login over plain HTTP is a password in the clear.
- Check it from outside the machine when you are done (*Check it*, below). A route that answers without asking for credentials is a bug
  to fix before anything else.

## Install the units

You need `tmux`, `python3`, [`uv`](https://docs.astral.sh/uv/) and `ttyd` (`sudo apt install ttyd` on Debian and Ubuntu; 1.7.7 is the
version the web UI was tested with).

```sh
~/salamander/install.sh --web          # copies the three units, starts nothing
cd ~/salamander/web && uv sync --frozen
systemctl --user daemon-reload
systemctl --user enable --now sala-web.socket sala-web.service sala-web-ttyd.service
loginctl enable-linger "$USER"         # the units keep running when you are not logged in
```

`install.sh --web` copies the units from `web/contrib/` to `${XDG_CONFIG_HOME:-~/.config}/systemd/user/` and writes this checkout's
path into their `ExecStart=` lines: as `%h/<path>` when the checkout is under your home (`~/salamander` gives
`%h/salamander/web/.venv/bin/sala-web`), as the absolute path otherwise. A plain `install.sh` installs no web unit (it only migrates old ones, below). It is safe to run
again; it overwrites the three files, so change a unit with a drop-in (`systemctl --user edit sala-web.service`), not in place.

Set `SALA_WEB_SOCKET` (the environment or sala's config file) before `install.sh --web` to pin the app's socket elsewhere: it is
written as `sala-web.socket`'s `ListenStream=`, and the proxy below must name the same path.

**An install from before the units were renamed** is migrated by `install.sh` or `deploy.sh` (`web/README.md`,
*Renamed units*). The proxy is not edited: for one release the old socket paths are symlinks to the new sockets, so a
Caddyfile or a cloudflared config that still names them keeps working. Point it at the paths below before the next release.

By hand instead: the units in `web/contrib/` name the checkout as `%h/salamander/web` (sala-web.service) and
`%h/salamander/web/contrib` (sala-web-ttyd.service). A checkout anywhere else needs that text changed in the copies, or a drop-in with an
empty `ExecStart=` line followed by the full line.

`sala-web-ttyd.service` runs `/usr/bin/ttyd`; if yours is elsewhere (`command -v ttyd`) use a drop-in the same way.

Without the proxy the web UI answers on its socket, to you only:

```sh
curl --unix-socket "$XDG_RUNTIME_DIR/sala-web/sala-web.sock" http://x/api/sessions
curl --unix-socket "$XDG_RUNTIME_DIR/sala-web-ttyd/ttyd.sock" -o /dev/null -w '%{http_code}\n' http://x/tty/    # 200
```

## A proxy with a login: Caddy

[Caddy](https://caddyserver.com/) gets a certificate (Let's Encrypt) by itself, passes websockets through, reaches unix sockets, and has
a basic-auth login in three lines. This example was tested; two more follow it.

What it needs:

- A name for the machine, here `sala.example.com`, with a DNS record to its public address and TCP ports 80 and 443 open to it (Let's
  Encrypt asks on both). On a machine behind a router, forward them. For a machine reachable only through a VPN, use
  the VPN's own HTTPS certificates instead and skip this example.
- Caddy running **as your user**, so it can open the 0600 sockets. The distribution's package starts its own system `caddy.service` on
  ports 80 and 443 as the user `caddy`, which cannot reach them; stop it for good: `sudo systemctl disable --now caddy`.
- Permission for your user to bind port 443. The usual way is one line of system configuration:
  `echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/50-unprivileged-ports.conf && sudo sysctl --system`
  (every local user may then bind ports 80 and above; on a shared machine give Caddy the capability instead:
  `sudo setcap cap_net_bind_service=+ep /usr/bin/caddy`, repeated after each package update).

The password hash goes into the Caddyfile; the password itself is typed, never put on a command line:

```sh
caddy hash-password        # asks twice, on the terminal; prints a $2a$... hash
```

`~/.config/sala-web/Caddyfile` (`chmod 600`), with `alice` and the hash replaced by your own:

```
{
	# the admin API is off: by default it listens on a localhost TCP port that any local user can use to reconfigure Caddy
	admin off
}

sala.example.com {
	# One login for everything below. Caddy 2.8 and later also accept the spelling basic_auth.
	basicauth {
		alice $2a$14$REPLACE_WITH_THE_OUTPUT_OF_caddy_hash-password
	}

	# ttyd: the Terminal tab and the Shell drawer
	@tty path /tty /tty/*
	handle @tty {
		reverse_proxy unix/{$XDG_RUNTIME_DIR}/sala-web-ttyd/ttyd.sock
	}

	# everything else is the web UI
	handle {
		reverse_proxy unix/{$XDG_RUNTIME_DIR}/sala-web/sala-web.sock
	}
}
```

`reverse_proxy` passes the `Host` header on unchanged, which ttyd's `--check-origin` and the web UI's own origin check on a POST need:
a proxy that rewrites `Host` breaks the terminal and every send. A second login-less site block, or a `handle` outside the `basicauth`,
is the hole the rule above forbids.

`~/.config/systemd/user/sala-web-proxy.service`:

```ini
[Unit]
Description=Caddy: HTTPS and a login in front of the sala-web web UI
After=network-online.target sala-web.socket sala-web-ttyd.service
Wants=network-online.target

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=%t
ExecStart=/usr/bin/caddy run --config %E/sala-web/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

```sh
caddy validate --config ~/.config/sala-web/Caddyfile --adapter caddyfile
systemctl --user daemon-reload && systemctl --user enable --now sala-web-proxy.service
```

A Caddyfile change is applied with `systemctl --user restart sala-web-proxy.service` (the admin API that `caddy reload` uses is off).

Basic auth has no limit on wrong guesses: use a long random password, and prefer one of the two examples below if the machine is on
the open internet and the login is all that stands between it and a shell.

## A sign-in with an account: Caddy and oauth2-proxy

[oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) signs the browser in with an account (Google, GitHub, any OpenID Connect
provider), and Caddy asks it about every request before passing it on. What the Caddy example above needs still holds (the name, the
ports, Caddy as your user and its unit); `sala.example.com`, `alice@example.com` and `/home/alice` are placeholders. The routing below
was run with Caddy 2.11.9 and oauth2-proxy 7.15.6, a password file standing in for the provider: no real provider's sign-in was part
of it.

What a request without a sign-in must get, which the web UI is built on:

| the request | the answer |
|---|---|
| a page load in a tab or the installed app (`Sec-Fetch-Dest: document`) | 302 to the sign-in page |
| everything else: the page's own requests, the event stream, a frame, a websocket upgrade | 401 |
| the manifest and the four icon files, by their exact paths | served: public |

On a 401 the open page loads itself again, once, and that page load arrives at the sign-in. A redirect in its place would lead a
background request to another origin, where the page could not tell what happened.

1. At the provider, make an OAuth client whose redirect URL is `https://sala.example.com/oauth2/callback`.
2. Put the `oauth2-proxy` binary of its [release](https://github.com/oauth2-proxy/oauth2-proxy/releases) in `~/.local/bin` (check the
   published checksum), then write its files, readable by you alone. The client secret is typed, never put on a command line:

```sh
mkdir -p -m 700 ~/.config/oauth2-proxy && cd ~/.config/oauth2-proxy
(umask 077; head -c 32 /dev/urandom > cookie-secret)
(umask 077; echo alice@example.com > emails)                      # who may sign in, one address a line
(umask 077; read -rsp 'client secret: ' s && printf %s "$s" > client-secret)
```

`~/.config/oauth2-proxy/oauth2-proxy.cfg`:

```toml
provider = "google"
client_id = "REPLACE_WITH_THE_CLIENT_ID"
client_secret_file = "/home/alice/.config/oauth2-proxy/client-secret"
cookie_secret_file = "/home/alice/.config/oauth2-proxy/cookie-secret"
redirect_url = "https://sala.example.com/oauth2/callback"

# an allow list of addresses. No email_domains line: "*" lets in any account the provider has, and an account here is a shell
authenticated_emails_file = "/home/alice/.config/oauth2-proxy/emails"
# only the cookie of a sign-in made here gets in, never a token a client brings along
skip_jwt_bearer_tokens = false

reverse_proxy = true
cookie_secure = true
cookie_expire = "168h"          # then a new sign-in
upstreams = ["static://202"]    # it answers Caddy's questions only; the traffic goes through Caddy
```

Leave `skip_provider_button` off: oauth2-proxy's sign-in page is what carries the part of an address after `#` through a first sign-in,
since a browser never sends it to a server: a link of before the page's views had paths (`/#s=<name>`) needs it. A view's own address
(`/s/<name>`) is in the sign-in's `rd`. Leave `cookie_refresh` unset: a renewed cookie does
not reach the browser through `forward_auth`.

`~/.config/systemd/user/oauth2-proxy.service` (the socket is mode 0600 in a 0700 directory, which systemd removes when the unit stops):

```ini
[Unit]
Description=oauth2-proxy: the sign-in in front of the sala-web web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
RuntimeDirectory=oauth2-proxy
RuntimeDirectoryMode=0700
UMask=0077
ExecStart=%h/.local/bin/oauth2-proxy --config=%E/oauth2-proxy/oauth2-proxy.cfg --http-address=unix://%t/oauth2-proxy/oauth2-proxy.sock,mode=0600
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

`~/.config/sala-web/Caddyfile`, in place of the one above (the same `sala-web-proxy.service` runs it):

```
{
	admin off
}

sala.example.com {
	# route: the three blocks are tried in the order written
	route {
		# the sign-in's own pages
		handle /oauth2/* {
			reverse_proxy unix/{$XDG_RUNTIME_DIR}/oauth2-proxy/oauth2-proxy.sock {
				header_up X-Real-IP {remote_host}
				header_up X-Forwarded-Uri {uri}
			}
		}

		# public: exactly these paths, compared as sent (a `path` matcher would also pass other spellings of them)
		@public expression `{path} in ['/manifest.webmanifest', '/static/icons/apple-touch-icon.png', '/static/icons/icon-192.png', '/static/icons/icon-512.png', '/static/icons/icon-512-maskable.png']`
		handle @public {
			reverse_proxy unix/{$XDG_RUNTIME_DIR}/sala-web/sala-web.sock
		}

		# everything else, /tty/ included: signed in, or refused
		handle {
			forward_auth unix/{$XDG_RUNTIME_DIR}/oauth2-proxy/oauth2-proxy.sock {
				uri /oauth2/auth
				header_up X-Real-IP {remote_host}

				@out status 401
				handle_response @out {
					@page header Sec-Fetch-Dest document
					redir @page /oauth2/sign_in?rd={%uri} 302
					respond 401
				}
			}

			@tty path /tty /tty/*
			reverse_proxy @tty unix/{$XDG_RUNTIME_DIR}/sala-web-ttyd/ttyd.sock
			reverse_proxy unix/{$XDG_RUNTIME_DIR}/sala-web/sala-web.sock
		}
	}
}
```

The redirect uses `{%uri}`, the placeholder that percent-encodes the address, so an `&` in the page's own query stays inside `rd` (with
`{uri}` the `rd` stops at the first `&`). It needs a Caddy that has this placeholder: the example was run with Caddy 2.11.9, and
Caddy 2.6.2 was reported to render it empty, which sends the sign-in no address at all. After a change, check it with a page whose
query has an `&` in it: the `rd` in the `Location` must decode to that address.

```sh
systemctl --user daemon-reload && systemctl --user enable --now oauth2-proxy.service
systemctl --user restart sala-web-proxy.service
```

Check it as under *Check it*, and the redirect and the public file too:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -H 'Sec-Fetch-Dest: document' https://sala.example.com/    # 302, to /oauth2/sign_in
curl -s -o /dev/null -w '%{http_code}\n' https://sala.example.com/manifest.webmanifest              # 200
```

What to expect once it runs:

- A sign-in ends after `cookie_expire`. The open page notices at its next request, keeps what was typed and not sent, and loads itself
  again once. If it is refused after that too, it stays as it is and shows what it shows for a lost connection.
- A connection already open (a session's live chat, a terminal) is not cut when the sign-in ends: it lasts until it drops. To shut
  someone out at once, take the address off the list, change the cookie secret and restart both `oauth2-proxy.service` and
  `sala-web-proxy.service`.
- A browser that sends no `Sec-Fetch-Dest` (Safari before 16.4) gets the 401 for a page load too; it signs in at
  `https://sala.example.com/oauth2/sign_in`.

## Another way: cloudflared with Cloudflare Access

Cloudflare's tunnel needs no open port and no certificate on the machine, and Access is the login (a one-time code mailed to an address
you list, or a Google or GitHub account). This outline was not run for this page; the settings are Cloudflare's own and may have moved.
At the time of writing the Zero Trust free plan covers up to 50 users, and a tunnel costs nothing: check the plan's current terms.

1. Put `example.com` on Cloudflare, install `cloudflared`, `cloudflared tunnel login`, `cloudflared tunnel create sala`.
2. **First** create the Access application (Zero Trust, Access, Applications, self-hosted) for `sala.example.com`, whole host, with one
   policy: Allow, Emails, `alice@example.com`. One application covers `/` and `/tty/`. Only then add the DNS route
   (`cloudflared tunnel route dns sala sala.example.com`), so the name never answers without the login.
3. `~/.cloudflared/config.yml`, running as your user (a user unit like the Caddy one above, `cloudflared tunnel run sala`):

```yaml
tunnel: sala
credentials-file: /home/alice/.cloudflared/<tunnel id>.json
ingress:
  - hostname: sala.example.com
    path: ^/tty(/|$)
    service: unix:/run/user/<uid>/sala-web-ttyd/ttyd.sock
  - hostname: sala.example.com
    service: unix:/run/user/<uid>/sala-web/sala-web.sock
  - service: http_status:404
```

`<uid>` is your user id (`id -u`; write the number in); cloudflared's file takes no `%t`. The ttyd rule comes first because the first rule that matches wins.

## Check it

From a machine that is not this one, or at least not through a saved login:

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://sala.example.com/            # 401 (Access: a redirect to its login page)
curl -s -o /dev/null -w '%{http_code}\n' https://sala.example.com/tty/         # 401, the same
curl -s -o /dev/null -w '%{http_code}\n' -u alice https://sala.example.com/    # asks for the password; 200
ss -ltnp                                                                       # no listener belongs to sala-web or ttyd
```

Then open the site in a browser, sign in, open a session's Terminal tab and press Ctrl+` for the Shell drawer: both load `/tty/`
from the same host, which is what `SALA_WEB_TERMINAL_URL` (default `/tty/?arg=`) points to, so a proxy that serves ttyd from another host
or path needs that variable set to match (`web/README.md`, *Settings*).

## Things to know

- The Shell drawer is a plain login shell in its own tmux session, which the web UI creates when it starts (if a tmux server is already running), when the drawer is opened and when the full-size page opens it. Terminal tab
  and drawer attach to the tmux server of your user (the default one); a private tmux server named with `SALA_WEB_TMUX_SOCKET` is read by
  `sala-web-ttyd-attach` too, if the unit gets the same `Environment=` line.
- ttyd serves one shell per open tab, as your user, with your whole home reachable. Treat the login as the key to the machine.
- The web UI reads sala's files under your home and `~/.claude`; it needs no other access, and runs as your user, not as root.
