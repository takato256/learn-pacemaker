#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
IMAGE=localhost/pacemaker-lab:rocky9
LABEL=io.pacemaker.sandbox
PROXY=/usr/lib/systemd/systemd-socket-proxyd

fail() { echo "エラー: $*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
使い方: sudo bash labctl.sh コマンド
  build                   接続可能な環境でイメージを作成
  create [人数=1] [待受IP=127.0.0.1]  参加者1〜10の環境とSSHを起動
  add 番号 [待受IP=127.0.0.1]        指定番号の環境だけを追加
  list                    ノード、待受IP、SSHポートを表示
  status [番号=1]          クラスタ状態を表示
  shell 番号 node01|node02  管理者用シェル
  check 番号               2ノード、クォーラム、VIP、HTTPを確認
  test 番号                standbyによる往復切り替えを実行
  isolation 番号 別番号    別環境へのSSH・HTTP接続が失敗することを確認
  access 番号              ホスト再起動後などにSSH待受を再開
  reset 番号               指定環境を削除して初期化
  destroy 番号             指定環境を削除
USAGE
}

lab_number() {
  [[ $1 =~ ^[0-9]{1,2}$ ]] || fail '番号・人数は1〜10を指定してください'
  local number=$((10#$1))
  (( number >= 1 && number <= 10 )) || fail '番号・人数は1〜10を指定してください'
  printf '%s\n' "$number"
}

select_lab() {
  N=$(lab_number "$1")
  printf -v LAB 'lab%02d' "$N"
  NET="$LAB-net"
  A="$LAB-node01"
  B="$LAB-node02"
  BASE=10.200.0
  local offset=$(((N - 1) * 8))
  SUBNET="$BASE.$offset/29"
  GATEWAY="$BASE.$((offset + 1))"
  IP_A="$BASE.$((offset + 2))"
  IP_B="$BASE.$((offset + 3))"
  VIP="$BASE.$((offset + 4))"
  PORT_A=$((22000 + N * 10 + 1))
  PORT_B=$((PORT_A + 1))
}

run_in() {
  local node=$1
  shift
  podman exec "$node" "$@"
}

node_label() {
  podman container inspect --format "{{index .Config.Labels \"$2\"}}" "$1"
}

owned() {
  [[ $(node_label "$1" "$LABEL") == "$LAB" ]] || fail "$1 は $LAB の管理対象ではありません"
}

network_owned() {
  [[ $(podman network inspect --format "{{index .Labels \"$LABEL\"}}" "$NET") == "$LAB" ]] ||
    fail "$NET は $LAB の管理対象ではありません"
}

lock_lab() {
  exec 9>"/run/lock/pacemaker-$LAB.lock"
  flock -n 9 || fail "$LAB は別の管理操作を実行中です"
}

preflight() {
  [[ -x $PROXY ]] || fail "$PROXY が必要です"
  [[ $(podman info --format '{{.Host.NetworkBackend}} {{.Host.CgroupVersion}}') == 'netavark v2' ]] ||
    fail 'Netavark と cgroup v2 が必要です'
  podman image exists "$IMAGE" || fail 'イメージを podman load で取り込むか、build を実行してください'
}

validate_bind() {
  local bind=$1 octet
  local -a octets
  [[ $bind =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $bind != 0.0.0.0 ]] ||
    fail '待受にはホストのIPv4アドレスを指定してください'
  IFS=. read -r -a octets <<< "$bind"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) && [[ $octet == "$((10#$octet))" ]] ||
      fail '待受IPv4アドレスを確認してください'
  done
}

wait_systemd() {
  local node=$1 state i
  for ((i=0; i<45; i++)); do
    state=$(run_in "$node" systemctl is-system-running 2>/dev/null || true)
    case $state in running|degraded) return 0;; esac
    sleep 2
  done
  podman logs --tail 30 "$node" >&2 || true
  fail "$node の systemd が起動しません"
}

members_ready() {
  local members
  members=$(run_in "$A" crm_node -l 2>/dev/null) || return 1
  awk -v a="$A" -v b="$B" '
    $2==a && $3=="member" {first=1}
    $2==b && $3=="member" {second=1}
    END {exit !(first && second)}
  ' <<< "$members"
}

wait_members() {
  local i
  for ((i=0; i<45; i++)); do
    if members_ready; then return 0; fi
    sleep 2
  done
  run_in "$A" pcs status --full >&2 || true
  fail '2ノードがクラスタに参加していません'
}

http_probe() {
  run_in "$1" curl --noproxy '*' -fsS --max-time 2 "http://$VIP/"
}

wait_http() {
  local expected=$1 peer=$A result i
  [[ $expected != "$A" ]] || peer=$B
  for ((i=0; i<45; i++)); do
    result=$(http_probe "$peer" 2>/dev/null || true)
    if [[ $result == "$expected" ]]; then
      printf 'HTTP OK %s → %s\n' "$VIP" "$result"
      return 0
    fi
    sleep 2
  done
  run_in "$A" pcs status --full >&2 || true
  fail "$peer から VIP $VIP を確認できませんでした (期待値: $expected)"
}

start_proxy() {
  local bind=$2 port=$3 ip=$4 unit="pm-$1-ssh"
  if systemctl is-active --quiet "$unit.socket"; then return 0; fi
  systemd-run --quiet --unit="$unit" --property=User=nobody \
    --property=NoNewPrivileges=yes --socket-property="ListenStream=$bind:$port" \
    "$PROXY" "$ip:22"
}

show_access() {
  local bind=$1
  printf '%s (VIP %s)\n  node01: ssh -p %s lab@%s\n  node02: ssh -p %s lab@%s\n' \
    "$LAB" "$VIP" "$PORT_A" "$bind" "$PORT_B" "$bind"
}

start_access() {
  local bind=$1
  start_proxy "$A" "$bind" "$PORT_A" "$IP_A"
  start_proxy "$B" "$bind" "$PORT_B" "$IP_B"
  show_access "$bind"
}

destroy_lab() {
  local node
  # 先に所有権を確認してから削除する。
  for node in "$A" "$B" "$LAB-client"; do
    if podman container exists "$node"; then owned "$node"; fi
  done
  if podman network exists "$NET"; then network_owned; fi
  for node in "$A" "$B"; do
    if systemctl is-active --quiet "pm-$node-ssh.socket" "pm-$node-ssh.service"; then
      systemctl stop "pm-$node-ssh.socket" "pm-$node-ssh.service"
    fi
  done
  # 旧構成を初期化する場合のクライアントとSSH中継も片付ける。
  for node in "$A" "$B" "$LAB-client"; do
    if systemctl is-active --quiet "pm-$node-ssh.service"; then
      systemctl stop "pm-$node-ssh.service"
    fi
    if podman container exists "$node"; then podman rm -f -t 30 "$node"; fi
  done
  if podman network exists "$NET"; then podman network rm "$NET"; fi
}

wait_pcsd() {
  local i
  for ((i=0; i<30; i++)); do
    if run_in "$A" timeout 2 bash -c ': > "/dev/tcp/$1/2224" && : > "/dev/tcp/$2/2224"' _ "$IP_A" "$IP_B" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  fail '両ノードの pcsd に接続できません'
}

create_lab() (
  local bind=$1 node ip pass cluster_pass
  for node in "$A" "$B" "$LAB-client"; do
    if podman container exists "$node"; then fail "$node は既に存在します。list で確認してください"; fi
  done
  if podman network exists "$NET"; then fail "$NET は既に存在します"; fi

  podman network create --driver bridge --internal --opt isolate=true \
    --subnet "$SUBNET" --gateway "$GATEWAY" --label "$LABEL=$LAB" "$NET"
  # 途中で失敗した場合は、この作成操作の資源だけを片付ける。
  trap 'rc=$?; if (( rc != 0 )); then destroy_lab; fi' EXIT

  read -r pass < /proc/sys/kernel/random/uuid
  pass="lab-${pass%%-*}"
  read -r cluster_pass < /proc/sys/kernel/random/uuid
  for node in "$A" "$B"; do
    ip=$IP_A
    [[ $node != "$B" ]] || ip=$IP_B
    podman run -d --pull=never --name "$node" --hostname "$node" \
      --label "$LABEL=$LAB" --label "$LABEL.bind=$bind" \
      --network "$NET" --ip "$ip" --systemd=always --stop-timeout 30 \
      --add-host "$A:$IP_A" --add-host "$B:$IP_B" \
      --memory 1024m --cpus 1 --pids-limit 512 --shm-size 128m --ulimit memlock=-1:-1 \
      --cap-add NET_ADMIN --cap-add SYS_NICE --cap-add SYS_RESOURCE --cap-add IPC_LOCK "$IMAGE"
    wait_systemd "$node"
    printf 'lab:%s\nhacluster:%s\n' "$pass" "$cluster_pass" | podman exec -i "$node" chpasswd
    run_in "$node" bash -c 'printf "%s\n" "$HOSTNAME" > /var/www/html/index.html'
    run_in "$node" ssh-keygen -A
    run_in "$node" /usr/sbin/sshd -t
    run_in "$node" systemctl enable --now sshd pcsd
  done

  wait_pcsd
  run_in "$A" pcs host auth "$A" "$B" -u hacluster -p "$cluster_pass"
  run_in "$A" pcs cluster setup "$LAB-cluster" "$A" "addr=$IP_A" "$B" "addr=$IP_B"
  run_in "$A" pcs cluster start --all
  run_in "$A" pcs cluster enable --all
  wait_members
  run_in "$A" pcs property set stonith-enabled=false
  run_in "$A" pcs resource defaults update resource-stickiness=100
  run_in "$A" pcs node standby "$B"
  run_in "$A" pcs resource create vip ocf:heartbeat:IPaddr2 ip="$VIP" cidr_netmask=29 op monitor interval=5s --group web-group
  run_in "$A" pcs resource create web systemd:httpd op monitor interval=10s --group web-group
  wait_http "$A"
  run_in "$A" pcs node unstandby "$B"
  start_access "$bind"
  printf 'SSHユーザー lab / パスワード %s\n' "$pass"
)

check_lab() {
  local node quorum first second active count=0
  owned "$A"
  owned "$B"
  run_in "$A" pcs status --full
  members_ready || fail '2ノードがクラスタに参加していません'
  quorum=$(run_in "$A" corosync-quorumtool -s)
  grep -Eq '^Quorate:[[:space:]]+Yes' <<< "$quorum" || fail 'クォーラムを確認できません'
  first=$(http_probe "$A")
  second=$(http_probe "$B")
  [[ $first == "$second" && ( $first == "$A" || $first == "$B" ) ]] ||
    fail '両ノードから同じHTTP応答を確認できません'
  active=$first
  for node in "$A" "$B"; do
    if run_in "$node" ip -4 -o addr show | awk -v vip="$VIP/29" '$4==vip {found=1} END {exit !found}'; then
      ((count+=1))
      [[ $node == "$active" ]] || fail 'VIPとHTTP応答のノードが一致しません'
    fi
  done
  [[ $count == 1 ]] || fail "VIPを持つノード数が1ではありません ($count)"
  echo "PASS $LAB: $VIP → $active"
}

test_lab() {
  check_lab
  [[ $(http_probe "$B") == "$A" ]] || fail 'node01を稼働系にしてから test を実行してください'
  run_in "$A" pcs node standby "$A"
  wait_http "$B"
  run_in "$B" pcs node unstandby "$A"
  run_in "$B" pcs node standby "$B"
  wait_http "$A"
  run_in "$A" pcs node unstandby "$B"
  check_lab
}

isolation_test() {
  select_lab "$1"
  local source=$A source_number=$N target routes rc
  owned "$source"
  routes=$(run_in "$source" ip -4 route show default)
  [[ -z $routes ]] || fail "$source にデフォルトルートがあります"
  select_lab "$2"
  [[ $N != "$source_number" ]] || fail '異なる番号を指定してください'
  check_lab
  for target in "$IP_A:22" "$IP_B:22" "$VIP:80"; do
    if run_in "$source" timeout 3 bash -c ': > "/dev/tcp/$1/$2"' _ "${target%:*}" "${target##*:}" 2>/dev/null; then
      fail "$source から別環境の $target に接続できました"
    else
      rc=$?
      [[ $rc == 1 || $rc == 124 ]] || fail "$source で疎通検査を実行できません ($rc)"
    fi
  done
  echo "PASS $source → $LAB の SSH・HTTP 接続遮断"
}

case ${1:-} in ''|-h|--help) usage; exit 0;; esac
[[ $EUID == 0 ]] || fail 'sudo bash labctl.sh で実行してください'
command -v podman >/dev/null || fail '先に sudo bash setup-host.sh を実行してください'
command=$1
shift

case $command in
  build)
    [[ $# == 0 ]] || fail 'build に引数は不要です'
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    podman build --pull=missing -t "$IMAGE" -f Containerfile .
    ;;
  create|add)
    [[ $# -le 2 ]] || fail "$command 番号または人数 [待受IP]"
    [[ $command != add || $# -ge 1 ]] || fail 'add 番号 [待受IP]'
    bind=${2:-127.0.0.1}
    validate_bind "$bind"
    preflight
    last=$(lab_number "${1:-1}")
    first=1
    [[ $command != add ]] || first=$last
    for ((j=first; j<=last; j++)); do
      select_lab "$j"
      lock_lab
      create_lab "$bind"
      exec 9>&-
    done
    ;;
  list)
    [[ $# == 0 ]] || fail 'list に引数は不要です'
    podman ps -a --filter "label=$LABEL" --format 'table {{.Names}}\t{{.Status}}'
    for ((j=1; j<=10; j++)); do
      select_lab "$j"
      if podman container exists "$A"; then
        bind=$(node_label "$A" "$LABEL.bind")
        if [[ -n $bind && $(node_label "$A" "$LABEL") == "$LAB" ]]; then show_access "$bind"; fi
      fi
    done
    ;;
  status)
    [[ $# -le 1 ]] || fail 'status [番号]'
    select_lab "${1:-1}"
    owned "$A"
    run_in "$A" pcs status --full
    ;;
  shell)
    [[ $# == 2 && ( $2 == node01 || $2 == node02 ) ]] || fail 'shell 番号 node01|node02'
    select_lab "$1"
    owned "$LAB-$2"
    podman exec -it "$LAB-$2" /bin/bash
    ;;
  isolation)
    [[ $# == 2 ]] || fail 'isolation 番号 別番号'
    isolation_test "$1" "$2"
    ;;
  check|test|access|reset|destroy)
    [[ $# == 1 ]] || fail "$command 番号"
    select_lab "$1"
    case $command in
      check) check_lab;;
      test) lock_lab; test_lab;;
      access)
        lock_lab
        owned "$A"
        owned "$B"
        bind=$(node_label "$A" "$LABEL.bind")
        validate_bind "$bind"
        start_access "$bind"
        ;;
      reset)
        lock_lab
        preflight
        bind=127.0.0.1
        if podman container exists "$A"; then
          owned "$A"
          saved_bind=$(node_label "$A" "$LABEL.bind")
          bind=${saved_bind:-$bind}
        fi
        validate_bind "$bind"
        destroy_lab
        create_lab "$bind"
        ;;
      destroy) lock_lab; destroy_lab;;
    esac
    ;;
  *) usage; exit 1;;
esac
