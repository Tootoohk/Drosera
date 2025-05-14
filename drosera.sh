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
    参考: Drosera 官方文档 https://dev.drosera.io/
EOF
}

############### 全局配置 ###############
TARGET_VERSION="v1.17.2"
TARGET_RPC="https://relay.testnet.drosera.io"

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

# 选择 docker-compose 命令
if command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  COMPOSE_CMD="docker compose"
fi

die(){ echo "[ERROR] $*" >&2; exit 1; }
safe_cd(){ mkdir -p "$1"; cd "$1" || die "无法进入目录 $1"; }

init_env(){
  [[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a
  export PATH="$HOME/.drosera/bin:$HOME/.bun/bin:$HOME/.foundry/bin:/usr/local/bin:$PATH"
}

########## 1) 安装依赖与工具 ##########
install_all(){
  echo "==> 安装/检查系统依赖"
  while fuser /var/lib/apt/lists/lock &>/dev/null; do sleep 1; done
  apt-get update && apt-get upgrade -y
  apt-get install -y software-properties-common unzip \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    make gcc nano jq git gettext-base || die "基础依赖安装失败"
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
  systemctl enable --now docker &>/dev/null || echo "[WARN] 无法启用 docker.service"
  sleep $WAIT_SHORT

  echo "==> 检查并安装 Docker Compose"
  if ! command -v docker-compose &>/dev/null; then
    echo "🔄 未检测到 docker-compose，开始安装…"
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
      -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose
    docker-compose --version &>/dev/null || die "Docker Compose 安装失败"
    echo "✔️ Docker Compose 安装完成 ($(docker-compose --version))"
  else
    echo "✔️ 检测到 docker-compose ($(docker-compose --version))，跳过下载"
  fi
  sleep $WAIT_SHORT

  echo "==> 检查并安装 Bun"
  if command -v bun &>/dev/null; then
    echo "✔️ bun 已安装 ($(bun --version))"
  else
    curl -fsSL https://bun.sh/install | bash || die "Bun 安装失败"
    export PATH="$HOME/.bun/bin:$PATH"
    echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "$HOME/.bashrc"
    sleep $WAIT_SHORT
  fi

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
  DROSERA_BIN_DIR="$HOME/.drosera/bin"
  curl -fsSL https://app.drosera.io/install | bash \
    || die "Drosera 安装脚本下载失败"
  "${DROSERA_BIN_DIR}/droseraup" \
    || die "droseraup 安装 drosera 失败"
  export PATH="$DROSERA_BIN_DIR:$PATH"
  echo "✔️ drosera 安装完成 ($(${DROSERA_BIN_DIR}/drosera --version))"
  sleep $WAIT_SHORT

  echo "==> 验证全部命令"
  for cmd in docker docker-compose bun forge drosera drosera-operator envsubst jq git; do
    command -v $cmd &>/dev/null || die "缺少命令：$cmd"
    echo "✔️ $cmd 就绪"
  done

  echo "所有依赖安装完毕！"
}



########## 2) 生成 docker-compose 模板（RPC 参数加双引号） ##########
generate_configs(){
  init_env
  echo "==> 生成 docker-compose 模板"
  safe_cd "$SCRIPT_HOME"
  set -a; source "$ENV_FILE"; set +a

  # 根据主机架构决定 platform 字段
  ARCH=$(uname -m)
  if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    PLATFORM_LINE="    platform: linux/amd64"
  else
    PLATFORM_LINE=""
  fi

  cat > "$TPL_FILE" << EOF
services:
  drosera:
${PLATFORM_LINE}
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
           --eth-rpc-url "\${ETH_RPC_URL}"
           --eth-backup-rpc-url "\${ETH_BACKUP_RPC_URL}"
           --drosera-address 0xea08f7d533C2b9A62F40D5326214f39a8E3A32F8
           --eth-private-key \${ETH_PRIVATE_KEY}
           --listen-address 0.0.0.0
           --network-external-p2p-address \${VPS_IP}
           --disable-dnr-confirmation true
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"

  drosera2:
${PLATFORM_LINE}
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
           --eth-rpc-url "\${ETH_RPC_URL}"
           --eth-backup-rpc-url "\${ETH_BACKUP_RPC_URL}"
           --drosera-address 0xea08f7d533C2b9A62F40D5326214f39a8E3A32F8
           --eth-private-key \${ETH_PRIVATE_KEY2}
           --listen-address 0.0.0.0
           --network-external-p2p-address \${VPS_IP}
           --disable-dnr-confirmation true
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"

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

  command -v bun    >/dev/null 2>&1 || { curl -fsSL https://bun.sh/install | bash; export PATH="$HOME/.bun/bin:$PATH"; }
  command -v forge  >/dev/null 2>&1 || { curl -fsSL https://foundry.paradigm.xyz | bash; export PATH="$HOME/.foundry/bin:$PATH"; foundryup; }
  command -v drosera >/dev/null 2>&1 || { curl -fsSL https://app.drosera.io/install | bash; export PATH="$HOME/.drosera/bin:$PATH"; droseraup; }

  git config --global user.email "drosera@local" || true
  git config --global user.name  "Drosera"       || true
  forge init -t "$TRAP_TEMPLATE" || die "Forge init 失败"
  bun install && forge build     || die "Forge build 失败"

  set -a; source "$ENV_FILE"; set +a

  echo "-> 首次 apply"
  retry=0
  while :; do
    printf 'ofc\n' | DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY" \
      drosera apply --eth-rpc-url "$ETH_RPC_URL" 2>&1 \
      | tee /tmp/first_apply.log || true
    if grep -qE "Created.*Trap Config|Updated.*Trap Config|No changes to apply" /tmp/first_apply.log; then
      echo "✔️ Trap Config apply 完成"; break
    fi
    ((retry++)) && [[ $retry -ge 3 ]] && die "首次 apply 失败，请查看 /tmp/first_apply.log"
    echo "等待冷却 ${COOLDOWN_WAIT}s… ($retry/3)"; sleep $COOLDOWN_WAIT
  done

  drosera dryrun --eth-rpc-url "$ETH_RPC_URL" || die "dryrun 失败"
  sleep $WAIT_SHORT

  echo "-> Bloom Boost 存入 $BLOOM_BOOST_AMOUNT ETH"
  TRAP_ADDRESS=$(grep -E '^[[:space:]]*address' drosera.toml | cut -d\" -f2)
  export DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY"
  printf 'ofc\n' | drosera bloomboost \
    --trap-address "$TRAP_ADDRESS" \
    --eth-amount   "$BLOOM_BOOST_AMOUNT" \
    2>&1 | tee /tmp/bloomboost.log || true
  if grep -q "Trap boosted" /tmp/bloomboost.log; then
    echo "✔️ Bloom Boost 成功"
  else
    cat /tmp/bloomboost.log; die "Bloom Boost 失败，请查看日志"
  fi
  unset DROSERA_PRIVATE_KEY
  sleep $WAIT_SHORT

  sed -i "/^TRAP_ADDRESS=/d" "$ENV_FILE"
  echo "TRAP_ADDRESS=$TRAP_ADDRESS" >> "$ENV_FILE"
  echo "Trap 合约部署完成：$TRAP_ADDRESS"
  sleep $WAIT_SHORT
}

register_and_start(){
  init_env
  echo "==> 注册 & 启动首台 Operator"

  # 1) 检测操作系统架构，决定下载哪种二进制
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)      ARCH_TAG="x86_64-unknown-linux-gnu";;
    aarch64|arm64) ARCH_TAG="aarch64-unknown-linux-gnu";;
    *)           die "不支持的架构: $ARCH";;
  esac

  # 2) 下载对应架构的 drosera-operator 并安装
  curl -fsSL "https://github.com/drosera-network/releases/releases/download/${TARGET_VERSION}/drosera-operator-${TARGET_VERSION}-${ARCH_TAG}.tar.gz" \
    -o /tmp/operator.tar.gz
  tar -xzf /tmp/operator.tar.gz -C /usr/local/bin drosera-operator
  rm /tmp/operator.tar.gz

  # 3) 在链上注册 Operator，最多重试 3 次
  echo "==> 注册 Operator"
  cnt=0
  while :; do
    out=$(drosera-operator register \
      --eth-rpc-url "$ETH_RPC_URL" \
      --eth-private-key "$ETH_PRIVATE_KEY" 2>&1) || true
    if [[ $? -eq 0 ]] || echo "$out" | grep -q OperatorAlreadyRegistered; then
      echo "✔️ 注册完成"
      break
    fi
    ((cnt++)) && [[ $cnt -ge 3 ]] && die "注册失败: $out"
    echo "等待 ${WAIT_SHORT}s… ($cnt/3)"
    sleep $WAIT_SHORT
  done

  # 4) 将第一台 Operator 写入本地 drosera.toml 的 whitelist
  echo "==> 将第一台 Operator 加入 whitelist"
  safe_cd "$TRAP_HOME"
  set -a; source "$ENV_FILE"; set +a
  sed -i "/^whitelist/c\whitelist = [\"${OPERATOR1_ADDRESS}\"]" drosera.toml

  # 5) 在链上 apply 更新后的 whitelist（处理 ConfigUpdateCooldownNotElapsed 重试）
  echo "==> 链上更新 whitelist"
  safe_cd "$TRAP_HOME"
  retry=0
  until printf 'ofc\n' | DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY" \
       drosera apply --eth-rpc-url "$ETH_RPC_URL" 2>&1 | tee /tmp/whitelist_apply.log; do
    if grep -q "ConfigUpdateCooldownNotElapsed" /tmp/whitelist_apply.log; then
      ((retry++)) && [[ $retry -ge 3 ]] && die "白名单 apply 冷却重试失败"
      echo "⚠️ 白名单操作还在冷却时间内，等待 ${COOLDOWN_WAIT}s… ($retry/3)"
      sleep $COOLDOWN_WAIT
      continue
    fi
    cat /tmp/whitelist_apply.log
    die "白名单 apply 失败，请查看 /tmp/whitelist_apply.log"
  done
  echo "✔️ 白名单 apply 完成"
  rm /tmp/whitelist_apply.log


  # 6) 渲染并启动 drosera 容器（自动拉取最新镜像）
  echo "==> 渲染并启动 drosera 容器"
  safe_cd "$SCRIPT_HOME"
  envsubst < "$TPL_FILE" > "$COMPOSE_FILE" || die "渲染 $COMPOSE_FILE 失败"
  $COMPOSE_CMD up -d --pull=always drosera || die "容器启动失败"
  sleep $WAIT_SHORT
}

########## 5) 添加第二台 Operator ##########
add_second_operator(){
  init_env
  echo "===== 添加第二台 Operator ====="
  [[ -f "$ENV_FILE" ]] || die ".env 不存在，请先生成配置"
  set -a; source "$ENV_FILE"; set +a

  # 1) 读或写入 ETH_PRIVATE_KEY2 & OPERATOR2_ADDRESS
  if [[ -n "${ETH_PRIVATE_KEY2:-}" && -n "${OPERATOR2_ADDRESS:-}" ]]; then
    echo "✔️ 检测到 .env 中已有第二台配置"
  else
    read -rp "第二台 私钥: " ETH_PRIVATE_KEY2
    read -rp "第二台 公钥地址: " OPERATOR2_ADDRESS
    sed -i "/^ETH_PRIVATE_KEY2=/d" "$ENV_FILE"
    sed -i "/^OPERATOR2_ADDRESS=/d" "$ENV_FILE"
    printf "ETH_PRIVATE_KEY2=\"%s\"\nOPERATOR2_ADDRESS=\"%s\"\n" \
      "$ETH_PRIVATE_KEY2" "$OPERATOR2_ADDRESS" >> "$ENV_FILE"
    set -a; source "$ENV_FILE"; set +a
  fi

  # 2) 在链上注册第二台 Operator
  echo "==> 注册第二台 Operator"
  cnt=0
  while :; do
    out=$(drosera-operator register \
      --eth-rpc-url "$ETH_RPC_URL" \
      --eth-private-key "$ETH_PRIVATE_KEY2" 2>&1) || true
    if [[ $? -eq 0 ]] || echo "$out" | grep -q OperatorAlreadyRegistered; then
      echo "✔️ 第二台 注册完成"
      break
    fi
    ((cnt++)) && [[ $cnt -ge 3 ]] && die "第二台 注册失败: $out"
    echo "等待 ${WAIT_SHORT}s… ($cnt/3)"; sleep $WAIT_SHORT
  done

  # 3) 更新本地 toml 白名单
  echo "==> 更新 drosera.toml 白名单"
  safe_cd "$TRAP_HOME"
  raw=$(grep -E '^[[:space:]]*whitelist' drosera.toml | sed -E 's/.*\[(.*)\].*/\1/')
  new_list="${raw},\"$OPERATOR2_ADDRESS\""
  sed -i "/^whitelist/c\whitelist = [$new_list]" drosera.toml
  grep -q '^private_trap' drosera.toml || echo 'private_trap = true' >> drosera.toml
  echo "✔️ drosera.toml 白名单更新: [$new_list]"

  # 4) 链上 apply 白名单更新
  echo "==> 链上 apply 白名单"
  retry=0
  until printf 'ofc\n' | DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY" \
        drosera apply --eth-rpc-url "$ETH_RPC_URL"; do
    ((retry++)) && [[ $retry -ge 3 ]] && die "白名单 apply 失败"
    echo "冷却 ${COOLDOWN_WAIT}s… ($retry/3)"; sleep $COOLDOWN_WAIT
  done
  echo "✔️ 白名单 apply 完成"

  # 5) 启动第二台容器
  echo "==> 启动 drosera2 容器"
  safe_cd "$SCRIPT_HOME"
  envsubst < "$TPL_FILE" > "$COMPOSE_FILE"
  $COMPOSE_CMD up -d drosera2 || die "drosera2 启动失败"
  sleep $WAIT_SHORT

  # 6) optin 第二台 Operator
  echo "==> 第二台 Operator optin"
  retry=0
  until drosera-operator optin \
      --eth-rpc-url "$ETH_RPC_URL" \
      --eth-private-key "$ETH_PRIVATE_KEY2" \
      --trap-config-address "$TRAP_ADDRESS"; do
    ((retry++)) && [[ $retry -ge 3 ]] && die "第二台 Opt-in 失败"
    echo "等待 ${WAIT_SHORT}s… ($retry/3)"; sleep $WAIT_SHORT
  done
  echo "✔️ 第二台 Opt-in 成功"
}


########## 6) 服务器迁移 功能 ##########
migrate_server(){
  print_banner
  echo "==> 服务器迁移"

  # —— 0) 准备 Trap 目录 —— 
  if [[ -f "$TRAP_HOME/drosera.toml" ]]; then
    echo "✔️ 已检测到完整的 Trap 目录：$TRAP_HOME"
  else
    if [[ -f "./trap.tar.gz" ]]; then
      ARCHIVE="trap.tar.gz"
    elif [[ -f "./my-drosera-trap.tar.gz" ]]; then
      ARCHIVE="my-drosera-trap.tar.gz"
    else
      die "缺少 Trap 合约目录 $TRAP_HOME 或打包文件 trap.tar.gz/my-drosera-trap.tar.gz  
请将 my-drosera-trap 目录打包后放在当前目录重试。"
    fi
    echo "✔️ 检测到 $ARCHIVE，正在解压到 $TRAP_HOME （去除顶层目录）..."
    mkdir -p "$TRAP_HOME"
    tar --strip-components=1 -xzf "./$ARCHIVE" -C "$TRAP_HOME" \
      || die "解压 $ARCHIVE 失败"
    echo "✔️ 解压完成：$TRAP_HOME"
  fi

  # —— 1) 准备 .env —— 
  if [[ -f "$ENV_FILE" ]]; then
    echo "✔️ 使用 ENV_FILE：$ENV_FILE"
  elif [[ -f "./.env" ]]; then
    echo "✔️ 检测到当前目录 .env，复制到脚本目录"
    mkdir -p "$(dirname "$ENV_FILE")"
    cp "./.env" "$ENV_FILE"
  else
    die "找不到 .env，请将其放到脚本目录或当前目录后重试"
  fi

  # —— 2) 安装依赖 & 生成 docker-compose 模板 —— 
  install_all
  generate_configs

  # —— 2.1) 渲染 docker-compose.yaml —— 
  echo "==> 渲染 docker-compose.yaml"
  safe_cd "$SCRIPT_HOME"
  envsubst < "$TPL_FILE" > "$COMPOSE_FILE" \
    || die "渲染 $COMPOSE_FILE 失败"
  echo "✔️ 已生成 $COMPOSE_FILE"

  # —— 3) 安装 drosera-operator CLI —— 
  echo "==> 安装 drosera-operator CLI"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) TAG="x86_64-unknown-linux-gnu";;
    aarch64|arm64) TAG="aarch64-unknown-linux-gnu";;
    *) die "不支持的架构: $ARCH";;
  esac
  curl -fsSL \
    "https://github.com/drosera-network/releases/releases/download/${TARGET_VERSION}/drosera-operator-${TARGET_VERSION}-${TAG}.tar.gz" \
    -o /tmp/op.tar.gz
  tar -xzf /tmp/op.tar.gz -C /usr/local/bin drosera-operator
  rm /tmp/op.tar.gz
  command -v drosera-operator &>/dev/null || die "drosera-operator 安装失败"
  echo "✔️ drosera-operator ($(drosera-operator --version))"

  # —— 4) 更新 toml 中 whitelist & address —— 
  set -a; source "$ENV_FILE"; set +a
  WL="\"$OPERATOR1_ADDRESS\",\"$OPERATOR2_ADDRESS\""
  sed -i "/^whitelist/c\whitelist = [$WL]" "$TRAP_HOME/drosera.toml"
  TRAP_ADDR=$(grep '^TRAP_ADDRESS=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"')
  sed -i "s|^address *=.*|address = \"$TRAP_ADDR\"|" "$TRAP_HOME/drosera.toml"
  echo "✔️ toml 更新：whitelist=[$WL]，address=\"$TRAP_ADDR\""

  # —— 5) 拉取镜像 —— 
  echo "==> 拉取镜像"
  $COMPOSE_CMD -f "$COMPOSE_FILE" pull \
    || die "镜像拉取失败"

  # —— 6) 单私钥 apply —— 
  echo "==> 应用 Trap Config（仅使用第一把私钥）"
  # 切换到 Trap 目录，drosera apply 会自动读取该目录下的 drosera.toml
  safe_cd "$TRAP_HOME"
  retry=0
  until printf 'ofc\n' | DROSERA_PRIVATE_KEY="$ETH_PRIVATE_KEY" \
       drosera apply --eth-rpc-url "$ETH_RPC_URL"; do
    ((retry++)) && [[ $retry -ge 3 ]] && die "ETH_PRIVATE_KEY apply 失败"
    echo "等待冷却 ${COOLDOWN_WAIT}s… ($retry/3)"; sleep $COOLDOWN_WAIT
  done
  echo "✔️ ETH_PRIVATE_KEY apply 完成"
  unset DROSERA_PRIVATE_KEY

  # —— 7) 启动容器 —— 
  echo "==> 启动容器"
  $COMPOSE_CMD -f "$COMPOSE_FILE" up -d \
    || die "容器启动失败"
  echo "✔️ 服务器迁移完成"
  read -rp "按任意键返回主菜单…" _
}




########## 查看日志 ##########
view_logs(){
  safe_cd "$SCRIPT_HOME"
  echo "1) drosera  2) drosera2  3) 全部"
  read -rp "日志选项: " c
  case $c in
    1) $COMPOSE_CMD logs -f drosera;;
    2) $COMPOSE_CMD logs -f drosera2;;
    3) $COMPOSE_CMD logs -f;;
    *) echo "无效选项"; sleep 1;;
  esac
}

########## 重启节点 ##########
restart_nodes(){
  safe_cd "$SCRIPT_HOME"
  echo "1) drosera  2) drosera2  3) 全部"
  read -rp "重启选项: " c
  case $c in
    1) $COMPOSE_CMD restart drosera;;
    2) $COMPOSE_CMD restart drosera2;;
    3) $COMPOSE_CMD down && $COMPOSE_CMD up -d;;
    *) echo "无效选项"; sleep 1;;
  esac
}

########## 一键部署 ##########
one_click_deploy(){
  print_banner
  safe_cd "$SCRIPT_HOME"

  read -rp "ETH RPC URL (默认 ${FOUNDATION_RPC}): " ETH_RPC_URL
  ETH_RPC_URL=${ETH_RPC_URL:-$FOUNDATION_RPC}
  read -rp "ETH 备用 RPC URL (默认 ${BACKUP_RPC}): " ETH_BACKUP_RPC_URL
  ETH_BACKUP_RPC_URL=${ETH_BACKUP_RPC_URL:-$BACKUP_RPC}

  read -rp "首台 私钥: " ETH_PRIVATE_KEY
  read -rp "首台 公钥地址: " OPERATOR1_ADDRESS

  read -rp "是否部署第二台? [y/N]: " yn
  if [[ $yn =~ ^[Yy]$ ]]; then
    read -rp "第二台 私钥: " ETH_PRIVATE_KEY2
    read -rp "第二台 公钥地址: " OPERATOR2_ADDRESS
  else
    ETH_PRIVATE_KEY2=""; OPERATOR2_ADDRESS=""
  fi

  read -rp "Bloom Boost ETH 数量 (默认 2): " BLOOM_BOOST_AMOUNT
  BLOOM_BOOST_AMOUNT=${BLOOM_BOOST_AMOUNT:-2}

  # 写入 .env（RPC 链接加双引号；添加两个公钥参数）
  cat > "$ENV_FILE" << EOF
ETH_RPC_URL="${ETH_RPC_URL}"
ETH_BACKUP_RPC_URL="${ETH_BACKUP_RPC_URL}"
ETH_PRIVATE_KEY="${ETH_PRIVATE_KEY}"
ETH_PRIVATE_KEY2="${ETH_PRIVATE_KEY2}"
OPERATOR1_ADDRESS="${OPERATOR1_ADDRESS}"
OPERATOR2_ADDRESS="${OPERATOR2_ADDRESS}"
BLOOM_BOOST_AMOUNT="${BLOOM_BOOST_AMOUNT}"
VPS_IP="$(curl -s https://api.ipify.org)"
EOF

  install_all
  generate_configs
  deploy_trap
  register_and_start
  [[ -n "$ETH_PRIVATE_KEY2" ]] && add_second_operator

  echo "✅ 一键部署完成！"
}

########## 升级节点到 ${TARGET_VERSION} ##########
upgrade_nodes(){
  init_env

  [[ -n "${ETH_RPC_URL:-}"     ]] || die "ETH_RPC_URL 未设置，请先生成 .env"
  [[ -n "${ETH_PRIVATE_KEY:-}" ]]  || die "ETH_PRIVATE_KEY 未设置，请先生成 .env"
  [[ -n "${ETH_PRIVATE_KEY2:-}" ]] || die "ETH_PRIVATE_KEY2 未设置，请先添加第二台 Operator"

  echo "==> 停止当前运行的节点容器"
  safe_cd "$SCRIPT_HOME"
  $COMPOSE_CMD stop drosera drosera2 || echo "[WARN] 停止容器时出错，可能已是停止状态"
  sleep $WAIT_SHORT

  # 1) 检查 Drosera CLI 版本
  echo "==> 检查 Drosera CLI 版本"
  inst_version=$("$HOME/.drosera/bin/drosera" --version | sed -E 's/^.*version[ v]*([0-9]+\.[0-9]+\.[0-9]+).*$/\1/')
  if [[ "$inst_version" != "${TARGET_VERSION#v}" ]]; then
    echo "==> 安装/升级 Drosera CLI 到 ${TARGET_VERSION}"
    grep -qxF 'export PATH=$PATH:$HOME/.drosera/bin' ~/.bashrc || \
      echo 'export PATH=$PATH:$HOME/.drosera/bin' >> ~/.bashrc
    curl -fsSL https://app.drosera.io/install | bash || die "Drosera 安装失败"
    set +u; source "$HOME/.bashrc"; set -u
    droseraup || echo "[WARN] droseraup 执行失败"
  else
    echo "✔️ Drosera CLI 已是最新版本 ($inst_version)"
  fi
  sleep $WAIT_SHORT

  # 2) 拉取所有服务镜像
  echo "==> 拉取所有服务镜像"
  safe_cd "$SCRIPT_HOME"
  $COMPOSE_CMD pull
  sleep $WAIT_SHORT

  # 3) 更新 drosera.toml 中的 drosera_rpc
  echo "==> 更新 Trap 配置中的 drosera_rpc"
  safe_cd "$TRAP_HOME"
  cp drosera.toml drosera.toml.bak-$(date +%s)
  sed -i "s|^drosera_rpc = .*|drosera_rpc = \"${TARGET_RPC}\"|" drosera.toml
  sleep $WAIT_SHORT

  # 4) 双私钥 apply
  for key in ETH_PRIVATE_KEY ETH_PRIVATE_KEY2; do
    priv="${!key}"
    retry=0
    echo "==> ${key} apply"
    until printf 'ofc\n' | DROSERA_PRIVATE_KEY="$priv" drosera apply --eth-rpc-url "$ETH_RPC_URL"; do
      ((retry++)) && [[ $retry -ge 3 ]] && die "${key} apply 重试失败"
      echo "冷却 ${COOLDOWN_WAIT}s… ($retry/3)"; sleep $COOLDOWN_WAIT
    done
    echo "✔️ ${key} apply 完成"
    unset DROSERA_PRIVATE_KEY
    sleep $WAIT_SHORT
  done

  # 5) 重启所有容器
  echo "==> 重启所有容器"
  safe_cd "$SCRIPT_HOME"
  $COMPOSE_CMD up -d
  echo "✔️ 升级到 ${TARGET_VERSION} 完成"
  read -rp "按任意键返回主菜单…" _
}

########## 设置 Bloom Boost 百分比 ##########
set_bloomboost_limit(){
  init_env
  echo "==> 设置 Bloom Boost 限制百分比"
  read -rp "请输入百分比（如 100 表示 1%）: " pct
  [[ -n "$pct" ]] || die "必须输入一个百分比"
  safe_cd "$TRAP_HOME"
  printf 'ofc\n' | drosera set-bloomboost-limit \
    --eth-rpc-url      "${ETH_RPC_URL}" \
    --drosera-rpc-url  "${TARGET_RPC}" \
    --limit            "${pct}" \
    || die "设置 Bloom Boost 限制失败"
  echo "✔️ 已将 Bloom Boost 限制设置为 $pct"
}

########## 主菜单 ##########
main_menu(){
  print_banner
  while true; do
    cat << EOF

=== Drosera 自动部署脚本 ===
1) 一键部署（傻瓜式）
2) 设置 Bloom Boost 限制
3) 查看日志
4) 重启节点
5) 添加第二台 Operator
6) 升级节点到 ${TARGET_VERSION}
7) 服务器迁移
0) 退出
EOF
    read -rp "请选择 [0-7]: " opt
    case $opt in
      1) one_click_deploy;;
      2) set_bloomboost_limit;;
      3) view_logs;;
      4) restart_nodes;;
      5) add_second_operator;;
      6) upgrade_nodes;;
      7) migrate_server;;
      0) exit 0;;
      *) echo "无效选项"; sleep 1;;
    esac
  done
}

main_menu
