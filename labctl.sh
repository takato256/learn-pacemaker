#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
CALLER_PWD=$PWD
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
IMAGE=localhost/pacemaker-lab:rocky9
LABEL=io.pacemaker.sandbox
fail(){ echo "ERROR: $*" >&2; exit 1; }
usage(){ cat <<'USAGE'
使い方 (rootful Podman): sudo ./labctl.sh COMMAND [ARGS]
  build                     イメージ作成
  create [人数=2]            lab01〜指定人数を新規作成 (1〜10)
  add LAB                   指定labを新規作成 (3〜10への拡張など)
  status [lab番号=1]         クラスタ状態
  shell LAB ROLE             node01/node02/client の管理者用シェル
  check LAB                  VIP/HTTP/クラスタ状態の検査
  test LAB                   node01→node02→node01 の自動系切替試験
  isolation LAB_A LAB_B      クライアントから別labへの疎通遮断を検査
  key LAB PUBLIC_KEY         参加者の公開鍵を3台に設定・SSHを起動
  proxy LAB [BIND_IP=127.0.0.1]  SSH用TCPプロキシを起動 (socat必要)
  unproxy LAB                SSH用TCPプロキシ停止
  reset LAB                  指定labを削除して初期状態で再作成 (鍵も消去)
  destroy LAB                指定labを削除
  list                      このキットのコンテナ一覧
USAGE
}
[[ $# -gt 0 ]] || { usage; exit 0; }
[[ $1 != -h && $1 != --help ]] || { usage; exit 0; }
[[ $EUID == 0 ]] || fail 'sudo で実行してください'
command -v podman >/dev/null || fail 'setup-host.sh を先に実行してください'
# 01等も許可するが数値範囲を限定
labnum(){ [[ $1 =~ ^[0-9]{1,2}$ ]] || fail 'LAB は1〜10'; local n=$((10#$1)); (( n>=1 && n<=10 )) || fail 'LAB は1〜10'; printf '%d' "$n"; }
select_lab(){ N=$(labnum "$1"); printf -v LAB 'lab%02d' "$N"; BASE="10.200.$N"; NET="${LAB}-net"; A="${LAB}-node01"; B="${LAB}-node02"; C="${LAB}-client"; VIP="$BASE.100"; }
owned(){ [[ $(podman inspect --format "{{index .Config.Labels \"$LABEL\"}}" "$1") == "$LAB" ]] || fail "$1 はこのlabの管理対象ではありません"; }
net_owned(){ [[ $(podman network inspect --format "{{index .Labels \"$LABEL\"}}" "$NET") == "$LAB" ]] || fail "$NET はこのlabの管理対象ではありません"; }
ex(){ local node=$1; shift; podman exec "$node" "$@"; }
wait_unit(){ local node=$1 unit=$2; for ((i=0;i<45;i++)); do if ex "$node" systemctl is-active --quiet "$unit"; then return 0; fi; sleep 2; done; ex "$node" journalctl -u "$unit" -n 30 --no-pager || true; fail "$node の $unit が起動しません"; }
wait_systemd(){ local node=$1 state; for ((i=0;i<45;i++)); do state=$(ex "$node" systemctl is-system-running 2>/dev/null || true); case $state in running|degraded) return 0;; esac; sleep 2; done; podman logs --tail 30 "$node" || true; fail "$node のsystemdが起動しません"; }
wait_http(){ local expected=$1 result; for ((i=0;i<45;i++)); do result=$(ex "$C" curl --noproxy '*' -fsS --max-time 2 "http://$VIP/" 2>/dev/null || true); if [[ $result == "$expected" ]]; then echo "HTTP OK: $VIP -> $result"; return 0; fi; sleep 2; done; ex "$A" pcs status --full || true; fail "VIP $VIP が $expected で応答しません (last=$result)"; }
both_members(){
  local members
  members=$(ex "$A" crm_node -l 2>/dev/null) || return 1
  awk -v a="$A" -v b="$B" '$2==a && $3=="member" {x=1} $2==b && $3=="member" {y=1} END{exit !(x&&y)}' <<< "$members"
}
wait_members(){
  for ((i=0;i<45;i++)); do if both_members; then return 0; fi; sleep 2; done
  ex "$A" pcs status --full || true; fail 'Pacemakerに2ノードが参加していません'
}
preflight(){
  [[ $(podman info --format '{{.Host.NetworkBackend}}') == netavark ]] || fail 'Netavark backend が必要です'
  [[ $(podman info --format '{{.Host.CgroupVersion}}') == v2 ]] || fail 'cgroup v2 が必要です'
  podman image exists "$IMAGE" || fail 'build を先に実行してください'
}
create_lab(){
  local node role ip pass
  for node in "$A" "$B" "$C"; do if podman container exists "$node"; then fail "$node が存在します。reset または destroy を使用してください"; fi; done
  if podman network exists "$NET"; then fail "$NET が存在します。destroy で整理してください"; fi
  echo "=== $LAB ($BASE.0/24) ==="
  podman network create --driver bridge --internal --opt isolate=true --subnet "$BASE.0/24" --gateway "$BASE.1" --label "$LABEL=$LAB" "$NET"
  for role in node01 node02 client; do
    local -a opts=()
    case $role in
      node01) node=$A; ip=11;; node02) node=$B; ip=12;; client) node=$C; ip=20;;
    esac
    if [[ $role == client ]]; then opts=(--memory 512m --cpus 0.5 --pids-limit 256); else
      opts=(--memory 1024m --cpus 1 --pids-limit 512 --cap-add NET_ADMIN --cap-add SYS_NICE --cap-add SYS_RESOURCE --cap-add IPC_LOCK --shm-size 128m --ulimit memlock=-1:-1)
    fi
    podman run -d --name "$node" --hostname "$node" --label "$LABEL=$LAB" \
      --network "$NET" --ip "$BASE.$ip" --systemd=always --stop-timeout 30 \
      --add-host "$A:$BASE.11" --add-host "$B:$BASE.12" --add-host "$C:$BASE.20" \
      "${opts[@]}" "$IMAGE"
    wait_systemd "$node"
  done
  # クラスタごとに異なる管理パスワード。画面に表示しない。
  pass=$(ex "$A" openssl rand -hex 24)
  for node in "$A" "$B"; do
    printf 'hacluster:%s\n' "$pass" | podman exec -i "$node" chpasswd
    ex "$node" bash -c 'printf "%s\n" "$(hostname)" > /var/www/html/index.html; printf "%s\n" "lab ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-lab; chmod 0440 /etc/sudoers.d/90-lab; visudo -cf /etc/sudoers.d/90-lab'
    ex "$node" systemctl enable --now pcsd
    wait_unit "$node" pcsd
  done
  ex "$A" pcs host auth "$A" "$B" -u hacluster -p "$pass"
  unset pass
  ex "$A" pcs cluster setup "${LAB}-cluster" "$A" "addr=$BASE.11" "$B" "addr=$BASE.12"
  ex "$A" pcs cluster start --all
  ex "$A" pcs cluster enable --all
  for node in "$A" "$B"; do wait_unit "$node" corosync; wait_unit "$node" pacemaker; done
  wait_members
  ex "$A" pcs property set stonith-enabled=false
  ex "$A" pcs resource defaults update resource-stickiness=100
  ex "$A" pcs node standby "$B"
  ex "$A" pcs resource create vip ocf:heartbeat:IPaddr2 ip="$VIP" cidr_netmask=24 op monitor interval=5s --group web-group
  ex "$A" pcs resource create web systemd:httpd op monitor interval=10s --group web-group
  wait_http "$A"
  ex "$A" pcs node unstandby "$B"
  ex "$A" pcs status --full
  echo "Created $LAB. 管理者: ./labctl.sh shell $N node01"
}
stop_proxies(){ local role; for role in node01 node02 client; do systemctl stop "pm-${LAB}-${role}-ssh.service" 2>/dev/null || true; done; }
destroy_lab(){
  local node
  # 所有確認を先に全件行う。衝突する既存資産は触らない。
  for node in "$A" "$B" "$C"; do if podman container exists "$node"; then owned "$node"; fi; done
  if podman network exists "$NET"; then net_owned; fi
  stop_proxies
  for node in "$A" "$B" "$C"; do if podman container exists "$node"; then podman rm -f -t 30 "$node"; fi; done
  if podman network exists "$NET"; then podman network rm "$NET"; fi
}
check_lab(){
  local result count=0 node has_vip
  for node in "$A" "$B" "$C"; do owned "$node"; done
  ex "$A" pcs status --full
  both_members || fail 'Pacemakerに2ノードが参加していません'
  local quorum
  quorum=$(ex "$A" corosync-quorumtool -s); printf '%s\n' "$quorum"
  grep -Eq '^Quorate:[[:space:]]+Yes' <<< "$quorum" || fail 'Quorumなし'
  result=$(ex "$C" curl --noproxy '*' -fsS --max-time 5 "http://$VIP/")
  [[ $result == "$A" || $result == "$B" ]] || fail "想定外のHTTP応答: $result"
  for node in "$A" "$B"; do
    ex "$node" systemctl is-active --quiet pacemaker
    has_vip=$(ex "$node" ip -4 -o addr show | awk -v vip="$VIP/24" '$4==vip {print $4}')
    if [[ -n $has_vip ]]; then ((count+=1)); [[ $node == "$result" ]] || fail 'VIPとHTTPの応答ノードが不一致'; fi
  done
  [[ $count == 1 ]] || fail "VIP保有ノード数=$count"
  echo "PASS: $LAB VIP=$VIP active=$result (VIP重複なし)"
}
case "$1" in
  build) [[ $# == 1 ]] || fail 'build は引数なし'; podman build -t "$IMAGE" -f Containerfile .;;
  create) [[ $# -le 2 ]] || fail 'create [人数]'; count=$(labnum "${2:-2}"); preflight; for ((j=1;j<=count;j++)); do select_lab "$j"; create_lab; done;;
  add) [[ $# == 2 ]] || fail 'add LAB'; select_lab "$2"; preflight; create_lab;;
  list) podman ps -a --filter "label=$LABEL" --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}';;
  status) select_lab "${2:-1}"; owned "$A"; ex "$A" pcs status --full;;
  shell) [[ $# == 3 ]] || fail 'shell LAB ROLE'; select_lab "$2"; case $3 in node01|node02|client) ;; *) fail 'ROLEが不正';; esac; owned "$LAB-$3"; podman exec -it "$LAB-$3" /bin/bash;;
  check) [[ $# == 2 ]] || fail 'check LAB'; select_lab "$2"; check_lab;;
  test) [[ $# == 2 ]] || fail 'test LAB'; select_lab "$2"; check_lab; [[ $(ex "$C" curl --noproxy '*' -fsS --max-time 5 "http://$VIP/") == "$A" ]] || fail '初期Activeがnode01ではありません。手順書で切り戻してください';
    ex "$A" pcs node standby "$A"; wait_http "$B"; check_lab
    ex "$B" pcs node unstandby "$A"; ex "$B" pcs node standby "$B"; wait_http "$A"; ex "$A" pcs node unstandby "$B"; check_lab; echo "PASS: $LAB 往復切替完了";;
  isolation) [[ $# == 3 ]] || fail 'isolation LAB_A LAB_B'; select_lab "$2"; owned "$C"; source_c=$C; source_n=$N; select_lab "$3"; [[ $N != "$source_n" ]] || fail '異なるLABを指定'; owned "$A"; owned "$C"; check_lab; ex "$source_c" ip route; [[ -z $(ex "$source_c" ip -4 route show default) ]] || fail 'clientにdefault routeあり';
    for target in "$BASE.11:2224" "$BASE.12:2224" "$VIP:80"; do host=${target%:*}; port=${target##*:}; if ex "$source_c" timeout 4 bash -c 'echo >/dev/tcp/$1/$2' _ "$host" "$port" 2>/dev/null; then fail "別labへ接続可能: $target"; fi; done; echo "PASS: $source_c -> $LAB の検査対象TCPポートは接続不可";;
  key) [[ $# == 3 ]] || fail 'key LAB PUBLIC_KEY'; key_input=$3; [[ $key_input == /* ]] || key_input="$CALLER_PWD/$key_input"; keyfile=$(realpath -e -- "$key_input" 2>/dev/null || true); [[ -n $keyfile && -f $keyfile ]] || fail '公開鍵が見つかりません'; [[ $(awk 'NF{n++} END{print n+0}' "$keyfile") == 1 ]] || fail '公開鍵は1行のみ'; grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( |$)' "$keyfile" || fail '通常のOpenSSH公開鍵を指定'; ssh-keygen -lf "$keyfile" >/dev/null; select_lab "$2";
    for node in "$A" "$B" "$C"; do owned "$node"; podman exec -i "$node" bash -c 'install -d -m 700 -o lab -g lab /home/lab/.ssh; cat > /home/lab/.ssh/authorized_keys; chown lab:lab /home/lab/.ssh/authorized_keys; chmod 600 /home/lab/.ssh/authorized_keys; ssh-keygen -A; /usr/sbin/sshd -t; systemctl enable --now sshd' < "$keyfile"; wait_unit "$node" sshd; done;;
  proxy) [[ $# -ge 2 && $# -le 3 ]] || fail 'proxy LAB [BIND_IP]'; select_lab "$2"; bind=${3:-127.0.0.1}; [[ $bind =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && $bind != 0.0.0.0 ]] || fail '明示的なVMのIPv4を指定 (0.0.0.0禁止)'; command -v socat >/dev/null || fail 'sudo dnf install -y socat';
    for node in "$A" "$B" "$C"; do owned "$node"; ex "$node" systemctl is-active --quiet sshd || fail 'key を先に実行'; done
    for role in node01 node02 client; do case $role in node01) off=1; dest=11;; node02) off=2; dest=12;; client) off=3; dest=20;; esac; port=$((22000+N*10+off)); unit="pm-${LAB}-${role}-ssh";
      systemd-run --unit "$unit" --property=User=nobody --property=NoNewPrivileges=yes --property=ProtectSystem=strict --property=ProtectHome=yes --property=TasksMax=64 --property=MemoryMax=128M /usr/bin/socat "TCP4-LISTEN:$port,bind=$bind,reuseaddr,fork" "TCP4:$BASE.$dest:22";
      sleep 0.3; systemctl is-active --quiet "$unit" || fail "$unit の起動失敗"; echo "ssh -p $port lab@$bind ($role)"; done;;
  unproxy) [[ $# == 2 ]] || fail 'unproxy LAB'; select_lab "$2"; stop_proxies;;
  reset) [[ $# == 2 ]] || fail 'reset LAB'; select_lab "$2"; preflight; destroy_lab; create_lab;;
  destroy) [[ $# == 2 ]] || fail 'destroy LAB'; select_lab "$2"; destroy_lab;;
  *) usage; exit 1;;
esac
