#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

print_banner(){
cat << 'EOF'

            ██████╗           ██╗  ██╗ 
           ██╔═══██╗          ██║ ██╔╝ 
           ██║   ██║          █████╔╝  
           ██║   ██║          ██╔═██╗  
           ╚██████╔╝          ██║  ██╗ 
            ╚═════╝           ╚═╝  ╚═╝ 

            Drosera 自动部署脚本
    作者: ChatGPT o4-mini-high、@Tootoohkk
    参考: 漆华@ferdie_jhovie 脚本 · 官方文档 https://dev.drosera.io/
EOF
}



############### 全局配置 ###############
DROPER_VER="v1.16.2"
TRAP_TEMPLATE="drosera-network/trap-foundry-template"
FOUNDATION_RPC="https://ethereum-holesky-rpc.publicnode.com"
BACKUP_RPC="https://holesky.drpc.org"

WAIT_SHORT=3
COOLDOWN_WAIT=420

SCRIPT_HOME="$HOME/drosera-deploy"
TRAP_HOME="$HOME/my-drosera-trap"

ENV_FILE="$SCRIPT_HOME/.env"
TPL_FILE="$SCRIPT_HOME/docker-compose.tpl.yaml"
COMPOSE_FILE="$SCRIPT_HOME/docker-compose.yaml"
#########################################

die(){ echo "[ERROR] $*" >&2; exit 1; }
safe_cd(){ mkdir -p "$1"; cd "$1" || die "无法进入目录 $1"; }

init_env(){
  [[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a
  export PATH="$HOME/.drosera/bin:$HOME/.bun/bin:$HOME/.foundry/bin:/usr/local/bin:$PATH"
}

########## 1) 安装依赖与工具 ##########
install_all(){
  echo "==> 安装/检查系统依赖"
  : "${PS1:=}"
  while fuser /var/lib/apt/lists/lock &>/dev/null; do sleep 1; done
  apt-get update && apt-get upgrade -y
  apt-get install -y software-properties-common unzip \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    make gcc nano jq git || die "基础依赖安装失败"
  echo "✔️ 基础依赖就绪"
  sleep $WAIT_SHORT

  echo "==> 检查并安装 Docker"
  if command -v docker &>/dev/null; then
    echo "✔️ 检测到 Docker $(docker --version | awk '{print $3}'), 跳过安装"
  else
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository -y \
      "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || die "Docker 安装失败"
    echo "✔️ Docker 安装完成"
  fi
  if command -v systemctl &>/dev/null; then
    systemctl enable --now docker \
      && echo "✔️ docker 服务已启用并启动" \
      || echo "[WARN] 无法启用/启动 docker.service，已跳过"
  fi
  sleep $WAIT_SHORT

  echo "==> 检查并安装 Bun"
  if command -v bun &>/dev/null; then
    echo "✔️ bun 已安装 ($(bun --version))"
  else
    curl -fsSL https://bun.sh/install | bash || die "Bun 安装失败"
    export PATH="$HOME/.bun/bin:$PATH"
    echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "$HOME/.bashrc"
    echo "✔️ bun 安装完成"
  fi
  sleep $WAIT_SHORT

  echo "==> 检查并安装 Foundry"
  if command -v forge &>/dev/null; then
    echo "✔️ forge 已安装 ($(forge --version))"
  else
    curl -fsSL https://foundry.paradigm.xyz | bash || die "Foundry 安装失败"
    export PATH="$HOME/.foundry/bin:$PATH"
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> "$HOME/.bashrc"
    set +u; source "$HOME/.bashrc"; set -u
    foundryup || die "foundryup 执行失败"
  fi
  sleep $WAIT_SHORT

  echo "==> 检查并安装 Drosera CLI"
  if command -v drosera &>/dev/null; then
    echo "✔️ drosera 已安装 ($(drosera --version))"
  else
    curl -fsSL https://app.drosera.io/install | bash || die "Drosera CLI 安装失败"
    export PATH="$HOME/.drosera/bin:$PATH"
    echo 'export PATH="$HOME/.drosera/bin:$PATH"' >> "$HOME/.bashrc"
    set +u; source "$HOME/.bashrc"; set -u
    droseraup || die "droseraup 执行失败"
  fi
  sleep $WAIT_SHORT

  echo "==> 验证其它命令"
  for cmd in docker docker-compose bun forge drosera drosera-operator envsubst jq git; do
    command -v $cmd &>/dev/null || die "缺少命令：$cmd"
    echo "✔️ $cmd 就绪"
  done
  echo "所有依赖安装完毕！"
}

########## 2) 根据现有 .env 生成 docker-compose 模板 ##########
generate_configs(){
  init_env
  echo "==> 生成 docker-compose 模板"
  safe_cd "$SCRIPT_HOME"
  set -a; source "$ENV_FILE"; set +a

  cat > "$TPL_FILE" <<'EOF'
services:
  drosera:
    image: ghcr.io/drosera-network/drosera-operator:latest
    container_name: drosera-node
    ports:
      - "31313:31313"
      - "31314:31314"
    volumes:
      - drosera_data:/data
    command: >
      node --db-file-path /data/drosera.db
           --network-p2p-port 31313
           --server-port 31314
           --eth-rpc-url ${ETH_RPC_URL}
           --eth-backup-rpc-url ${ETH_BACKUP_RPC_URL}
           --drosera-address 0xea08f7d533C2b9A62F40D5326214f39a8E3A32F8
           --eth-private-key ${ETH_PRIVATE_KEY}
           --listen-address 0.0.0.0
           --network-external-p2p-address ${VPS_IP}
           --disable-dnr-confirmation true
    restart: always

  drosera2:
    image: ghcr.io/drosera-network/drosera-operator:latest
    container_name: drosera-node-2
    ports:
      - "31315:31315"
      - "31316:31316"
    volumes:
      - drosera_data_2:/data
    command: >
      node --db-file-path /data/drosera.db
           --network-p2p-port 31315
           --server-port 31316
           --eth-rpc-url ${ETH_RPC_URL}
           --eth-backup-rpc-url ${ETH_BACKUP_RPC_URL}
           --drosera-address 0xea08f7d533C2b9A62F40D5326214f39a8E3A32F8
           --eth-private-key ${ETH_PRIVATE_KEY2}
           --listen-address 0.0.0.0
           --network-external-p2p-address ${VPS_IP}
           --disable-dnr-confirmation true
    restart: always

volumes:
  drosera_data:
  drosera_data_2:
EOF

  echo "模板生成完毕"
  sleep $WAIT_SHORT
}

########## 3) 部署 Trap 合约 & Bloom Boost ##########
deploy_trap(){
  init_env
  echo "==> 部署 Trap 合约"
  safe_cd "$TRAP_HOME"
  # rm -rf "$TRAP_HOME"/*
  # 确保工具
  command -v bun    >/dev/null 2>&1 || { curl -fsSL https://bun.sh/install | bash; export PATH="$HOME/.bun/bin:$PATH"; }
  command -v forge  >/dev/null 2>&1 || { curl -fsSL https://foundry.paradigm.xyz | bash; export PATH="$HOME/.foundry/bin:$PATH"; foundryup; }
  command -v drosera >/dev/null 2>&1 || { curl -fsSL https://app.drosera.io/install | bash; export PATH="$HOME/.drosera/bin:$PATH"; droseraup; }

  git config --global user.email "drosera@local" || true
  git config --global user.name  "Drosera"       || true
  forge init -t "$TRAP_TEMPLATE" || die "Forge init 失败"
  bun install && forge build        || die "Forge build 失败"

  set -a; source "$ENV_FILE"; set +a

  echo "-> 首次 apply"
  retry=0
  while true; do
    printf 'ofc\n' | DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY" \
      drosera apply --eth-rpc-url "$ETH_RPC_URL" 2>&1 | tee /tmp/first_apply.log || true
    if grep -qE "Created.*Trap Config|Updated.*Trap Config|No changes to apply" /tmp/first_apply.log; then
      echo "✔️ Trap Config apply 完成"
      break
    fi
    ((retry++))&&[[ $retry -ge 3 ]]&&die "首次 apply 失败，请查看 /tmp/first_apply.log"
    echo "等待冷却 ${COOLDOWN_WAIT}s… ($retry/3)"; sleep $COOLDOWN_WAIT
  done

  drosera dryrun --eth-rpc-url "$ETH_RPC_URL" || die "dryrun 失败"
  sleep $WAIT_SHORT

  echo "-> Bloom Boost 存入 $BLOOM_BOOST_AMOUNT ETH"
  TRAP_ADDRESS=$(grep -E '^[[:space:]]*address' drosera.toml | cut -d\" -f2)
  export DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY"
  printf 'ofc\n' | drosera bloomboost \
    --trap-address "$TRAP_ADDRESS" \
    --eth-amount   "$BLOOM_BOOST_AMOUNT" 2>&1 \
    | tee /tmp/bloomboost.log || true
  if grep -q "Trap boosted" /tmp/bloomboost.log; then
    echo "✔️ Bloom Boost 成功"
  else
    cat /tmp/bloomboost.log; die "Bloom Boost 失败，请查看 /tmp/bloomboost.log"
  fi
  unset DROSERA_PRIVATE_KEY
  sleep $WAIT_SHORT

  # —— 自动白名单，无需再手动输入 Operator 公钥 —— 
  OP_ADDR="${OPERATOR1_ADDRESS}"
  echo "-> 使用第一台 Operator 公钥加入白名单: $OP_ADDR"
  sed -i "/^[[:space:]]*whitelist/c\whitelist = [\"$OP_ADDR\"]" drosera.toml
  grep -q '^private_trap' drosera.toml || echo 'private_trap = true' >> drosera.toml

  echo "-> 白名单 apply"
  retry=0
  while true; do
    printf 'ofc\n' | DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY" \
      drosera apply --eth-rpc-url "$ETH_RPC_URL" 2>&1 \
      | tee /tmp/whitelist_apply.log || true
    cleaned=$(sed -r 's/\x1B\[[0-9;]*[mK]//g' /tmp/whitelist_apply.log)
    echo "---- 白名单 apply 日志 ----"; echo "$cleaned"; echo "--------------------------"
    if echo "$cleaned" | grep -qE "Created.*Trap Config|Updated.*Trap Config|No changes to apply"; then
      echo "✔️ 白名单 apply 完成"; break
    fi
    ((retry++))&&[[ $retry -ge 3 ]]&&die "白名单 apply 失败，请查看 /tmp/whitelist_apply.log"
    echo "等待冷却 ${COOLDOWN_WAIT}s… ($retry/3)"; sleep $COOLDOWN_WAIT
  done

  sed -i "/^TRAP_ADDRESS=/d" "$ENV_FILE"
  echo "TRAP_ADDRESS=$TRAP_ADDRESS" >> "$ENV_FILE"
  echo "Trap 合约部署完成：$TRAP_ADDRESS"
  sleep $WAIT_SHORT
}

########## 4) 设置 Bloom Boost 限制百分比 ##########
set_bloomboost_limit(){
  init_env
  echo "==> 设置 Bloom Boost 限制百分比"
  echo "详情查看官方文档：https://dev.drosera.io/docs/trappers/setting-bloomboost-percentage"
  read -rp "请输入 Bloom Boost 限制百分比 (例：100 = 1%，输入100则每次触发扣除余额1%): " pct
  [[ -n "$pct" ]] || die "必须输入一个百分比"

  # 切到 Trap 目录，确保找到 drosera.toml
  safe_cd "$TRAP_HOME"

  echo "-> 执行 drosera set-bloomboost-limit ..."
  # 用 printf 而非 yes，避免 SIGPIPE
  printf 'ofc\n' | drosera set-bloomboost-limit \
    --eth-rpc-url      "$ETH_RPC_URL" \
    --drosera-rpc-url  "https://seed-node.testnet.drosera.io" \
    --eth-chain-id     17000 \
    --drosera-address  "0xea08f7d533C2b9A62F40D5326214f39a8E3A32F8" \
    --private-key      "$ETH_PRIVATE_KEY" \
    --trap-address     "$TRAP_ADDRESS" \
    --limit            "$pct" \
    || die "设置 Bloom Boost 限制失败"

  echo "✔️ 已将 Bloom Boost 限制设置为 $pct"
}



########## 5) 注册 & 启动首台 Operator ##########
register_and_start(){
  echo "==> 注册 & 启动首台 Operator"
  safe_cd ~

  curl -fsSL "https://github.com/drosera-network/releases/releases/download/$DROPER_VER/drosera-operator-$DROPER_VER-x86_64-unknown-linux-gnu.tar.gz" \
    -o drosera-operator.tar.gz
  tar -xzf drosera-operator.tar.gz drosera-operator && mv drosera-operator /usr/local/bin/
  docker pull ghcr.io/drosera-network/drosera-operator:latest
  sleep $WAIT_SHORT

  init_env
  cnt=0
  while true; do
    out=$(drosera-operator register --eth-rpc-url "$ETH_RPC_URL" --eth-private-key "$ETH_PRIVATE_KEY" 2>&1)||true
    if [[ $? -eq 0 ]] || echo "$out" | grep -q OperatorAlreadyRegistered; then
      echo "✔️ 注册完成"; break
    fi
    ((cnt++))&&[[ $cnt -ge 3 ]]&&die "注册失败：$out"
    echo "等待 ${WAIT_SHORT}s… ($cnt/3)"; sleep $WAIT_SHORT
  done

  echo "-> 启动 drosera 容器"
  safe_cd "$SCRIPT_HOME"
  envsubst < "$TPL_FILE" > "$COMPOSE_FILE"
  docker-compose -f "$COMPOSE_FILE" up -d drosera
  sleep $WAIT_SHORT

  cnt=0
  while true; do
    out=$(drosera-operator optin --eth-rpc-url "$ETH_RPC_URL" --eth-private-key "$ETH_PRIVATE_KEY" --trap-config-address "$TRAP_ADDRESS" 2>&1)||true
    if [[ $? -eq 0 ]]; then echo "✔️ 首台 Operator Opt-in 成功"; break; fi
    ((cnt++))&&[[ $cnt -ge 3 ]]&&die "首台 Opt-in 失败：$out"
    echo "等待 ${WAIT_SHORT}s… ($cnt/3)"; sleep $WAIT_SHORT
  done

  echo
  echo "==> 首台 Operator 启动并 Opt-in 完成"
  echo "提示：如需查看日志，请运行“功能 3”"
}

########## 6) 添加第二台 Operator ##########
add_second_operator(){
  init_env
  echo "===== 添加第二台 Operator ====="
  [[ -f "$ENV_FILE" ]] || die ".env 不存在，请先生成配置"

  # 加载 .env，如果已有第二台配置就跳过提示
  set -a; source "$ENV_FILE"; set +a
  if [[ -n "${ETH_PRIVATE_KEY2:-}" && -n "${OPERATOR2_ADDRESS:-}" ]]; then
    echo "✔️ 检测到 .env 中已有第二台配置，直接使用："
    echo "   私钥:  ${ETH_PRIVATE_KEY2:0:6}····"
    echo "   公钥:  $OPERATOR2_ADDRESS"
  else
    # 提示用户输入
    read -rp "第二台 Operator 私钥: " ETH_PRIVATE_KEY2
    [[ -n "$ETH_PRIVATE_KEY2" ]] || { echo "已取消"; return; }
    read -rp "第二台 Operator 公钥地址: " OPERATOR2_ADDRESS
    [[ -n "$OPERATOR2_ADDRESS" ]] || die "未提供第二台公钥"

    # 写入 .env
    sed -i "/^ETH_PRIVATE_KEY2=/d" "$ENV_FILE"
    sed -i "/^OPERATOR2_ADDRESS=/d" "$ENV_FILE"
    {
      echo "ETH_PRIVATE_KEY2=$ETH_PRIVATE_KEY2"
      echo "OPERATOR2_ADDRESS=$OPERATOR2_ADDRESS"
    } >> "$ENV_FILE"
    echo "✔️ 已将第二台配置写入 .env"
  fi

  # 重新加载，确保后续步骤可用
  set -a; source "$ENV_FILE"; set +a

  # 确保 Trap 已部署
  [[ -n "${TRAP_ADDRESS:-}" ]] || die "TRAP_ADDRESS 未设置，请先部署 Trap"

  safe_cd "$TRAP_HOME"

  echo "→ 更新 drosera.toml 白名单"
  raw=$(grep -E '^[[:space:]]*whitelist' drosera.toml || true)
  raw=${raw#*[}; raw=${raw%]*}; raw=${raw//\"/}
  [[ -z "${raw// }" ]] && new="\"$OPERATOR2_ADDRESS\"" || new="\"$raw\",\"$OPERATOR2_ADDRESS\""
  sed -i "/^[[:space:]]*whitelist/c\whitelist = [$new]" drosera.toml
  grep -q '^private_trap' drosera.toml || echo 'private_trap = true' >> drosera.toml
  echo "✔️ drosera.toml 白名单更新为: [$new]"

  echo "-> 白名单 apply"
  retry=0
  while true; do
    printf 'ofc\n' | DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY" \
      drosera apply --eth-rpc-url "$ETH_RPC_URL" 2>&1 \
      | tee /tmp/second_whitelist.log || true

    # 去掉颜色编码方便阅读
    cleaned=$(sed -r 's/\x1B\[[0-9;]*[mK]//g' /tmp/second_whitelist.log)
    echo "---- apply 日志 ----"; echo "$cleaned"; echo "--------------------"

    if echo "$cleaned" | grep -qE "Created.*Trap Config|Updated.*Trap Config|No changes to apply"; then
      echo "✔️ 第二台 白名单 apply 成功"
      break
    fi

    ((retry++)) && [[ $retry -ge 3 ]] && die "第二台 白名单 apply 多次失败，请查看 /tmp/second_whitelist.log"
    echo "等待冷却 ${COOLDOWN_WAIT}s… ($retry/3)"
    sleep $COOLDOWN_WAIT
  done

  echo "==> 注册第二台 Operator"
  retry=0
  while true; do
    out=$(drosera-operator register \
          --eth-rpc-url "$ETH_RPC_URL" \
          --eth-private-key "$ETH_PRIVATE_KEY2" 2>&1) || true
    if [[ $? -eq 0 ]] || echo "$out" | grep -q OperatorAlreadyRegistered; then
      echo "✔️ 第二台 注册完成"
      break
    fi
    ((retry++)) && [[ $retry -ge 3 ]] && die "第二台 注册失败：$out"
    echo "等待 ${WAIT_SHORT}s… ($retry/3)"; sleep $WAIT_SHORT
  done

  echo "==> 启动第二台 drosera2"
  safe_cd "$SCRIPT_HOME"
  envsubst < "$TPL_FILE" > "$COMPOSE_FILE"
  docker-compose -f "$COMPOSE_FILE" up -d drosera2
  echo "✔️ drosera2 已启动"
  sleep $WAIT_SHORT

  echo "==> 第二台 Opt-in"
  retry=0
  while true; do
    out=$(drosera-operator optin \
          --eth-rpc-url "$ETH_RPC_URL" \
          --eth-private-key "$ETH_PRIVATE_KEY2" \
          --trap-config-address "$TRAP_ADDRESS" 2>&1) || true
    if [[ $? -eq 0 ]]; then
      echo "✔️ 第二台 Opt-in 成功"
      break
    fi
    ((retry++)) && [[ $retry -ge 3 ]] && die "第二台 Opt-in 失败：$out"
    echo "等待 ${WAIT_SHORT}s… ($retry/3)"; sleep $WAIT_SHORT
  done
}

########## 7) 一键部署（依次执行 1–6） ##########
one_click_deploy(){
  print_banner
  safe_cd "$SCRIPT_HOME"

  read -rp "ETH RPC URL (默认 ${FOUNDATION_RPC}): " ETH_RPC_URL
  ETH_RPC_URL=${ETH_RPC_URL:-$FOUNDATION_RPC}
  read -rp "ETH 备用 RPC URL (默认 ${BACKUP_RPC}): " ETH_BACKUP_RPC_URL
  ETH_BACKUP_RPC_URL=${ETH_BACKUP_RPC_URL:-$BACKUP_RPC}
  read -rp "首台 Operator 私钥: " ETH_PRIVATE_KEY
  [[ -n "$ETH_PRIVATE_KEY" ]]||die
  read -rp "首台 Operator 公钥地址: " OPERATOR1_ADDRESS
  [[ -n "$OPERATOR1_ADDRESS" ]]||die
  read -rp "是否部署第二台 Operator? [y/N]: " yn
  [[ "$yn" =~ ^[Yy] ]] && read -rp "第二台 Operator 私钥: " ETH_PRIVATE_KEY2 && read -rp "第二台 Operator 公钥地址: " OPERATOR2_ADDRESS || { ETH_PRIVATE_KEY2=""; OPERATOR2_ADDRESS=""; }
  read -rp "Bloom Boost 存入数量(ETH 建议≥2; 默认2): " BLOOM_BOOST_AMOUNT
  BLOOM_BOOST_AMOUNT=${BLOOM_BOOST_AMOUNT:-2}

  cat > "$ENV_FILE" <<EOF
ETH_RPC_URL=$ETH_RPC_URL
ETH_BACKUP_RPC_URL=$ETH_BACKUP_RPC_URL
ETH_PRIVATE_KEY=$ETH_PRIVATE_KEY
ETH_PRIVATE_KEY2=$ETH_PRIVATE_KEY2
OPERATOR1_ADDRESS=$OPERATOR1_ADDRESS
OPERATOR2_ADDRESS=$OPERATOR2_ADDRESS
BLOOM_BOOST_AMOUNT=$BLOOM_BOOST_AMOUNT
VPS_IP=$(curl -s https://api.ipify.org || echo "")
# TRAP_ADDRESS 后续写入
EOF

  generate_configs
  install_all
  deploy_trap
  register_and_start
  [[ -n "$ETH_PRIVATE_KEY2" ]] && add_second_operator

  echo "✅ 一键部署完成！"
}

view_logs(){
  safe_cd "$SCRIPT_HOME"
  echo "1) drosera  2) drosera2  3) 全部"
  read -rp "日志选项: " c
  case $c in
    1) docker-compose -f "$COMPOSE_FILE" logs -f drosera;;
    2) docker-compose -f "$COMPOSE_FILE" logs -f drosera2;;
    3) docker-compose -f "$COMPOSE_FILE" logs -f;;
    *) echo "无效"; sleep 1;;
  esac
}

restart_nodes(){
  safe_cd "$SCRIPT_HOME"
  echo "1) drosera  2) drosera2  3) 全部"
  read -rp "重启选项: " c
  case $c in
    1) docker-compose -f "$COMPOSE_FILE" restart drosera;;
    2) docker-compose -f "$COMPOSE_FILE" restart drosera2;;
    3) docker-compose -f "$COMPOSE_FILE" down && docker-compose -f "$COMPOSE_FILE" up -d;;
    *) echo "无效"; sleep 1;;
  esac
}

main_menu(){
  print_banner
  while true; do
    cat <<EOF

=== Drosera 自动部署脚本 2.0 ===
1) 一键部署
2) 设置 Bloom Boost 限制百分比
3) 查看日志
4) 重启节点
5) 添加第二台 Operator
0) 退出
EOF
    read -rp "请选择 [0-5]: " opt
    case $opt in
      1) one_click_deploy;;
      2) set_bloomboost_limit;;
      3) view_logs;;
      4) restart_nodes;;
      5) add_second_operator;;
      0) exit 0;;
      *) echo "无效选项"; sleep 1;;
    esac
  done
}

main_menu
