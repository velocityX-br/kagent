#!/usr/bin/env bash
#
# kagent 本地部署 —— 环境预备脚本（受限网络 + SAP HAI Proxy）
#
# 作用：把「可自动化的准备步骤」一键跑完，幂等可重复执行：
#   1) 准备 ~/.kube/config（否则 use-kind-cluster 的 chmod 会失败）
#   2) 把所有被墙/第三方镜像用「同 digest 的可达源」预拉进 kind 节点
#   3) 打印下一步要手动跑的构建/安装命令
#
# 不做的事（需要你手动跑，因为涉及耗时构建或敏感 key）：
#   - make create-kind-cluster     （若集群还没建）
#   - make build ...               （构建 6 个组件镜像）
#   - OPENAI_API_KEY=... make kagent-cli-deploy ...
#
# 用法：
#   bash scripts/local/prepare-kagent-local.sh
#
# 可用环境变量覆盖默认值（与 Makefile 的默认一致）：
#   KIND_CLUSTER_NAME   默认 kagent
#   KIND_NODE           默认 <cluster>-control-plane
set -euo pipefail

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kagent}"
KIND_NODE="${KIND_NODE:-${KIND_CLUSTER_NAME}-control-plane}"

# ── 同 digest 的可达镜像源（必须与 Makefile 里的覆盖值保持一致）──────────────
POSTGRES_IMAGE="public.ecr.aws/docker/library/postgres@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"
RUSTFS_IMAGE="quay.io/rustfs/rustfs:1.0.3@sha256:9ca9559533b537d10482fe923288b676ad08f92a7069d9a17327fbae3cab688b"
AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.38.5@sha256:c8156a0e74e13929a42d7e60f0d4e14e7d28d980cd21822505d4bff80e5460c1"
AGENTGATEWAY_IMAGE="cr.agentgateway.dev/agentgateway:v1.7.0@sha256:60216aafb03d37f94e952ff3d51d2f630a65b10ecaebdc0a864882f92610c45b"

# substrate / podcert 组件镜像（ghcr.io，可达）
GHCR_PREFIX="ghcr.io/kagent-dev/substrate"
SUBSTRATE_TAG="v1.0.0"
GHCR_IMAGES=(
  "${GHCR_PREFIX}/ate-idp-server:${SUBSTRATE_TAG}"
  "${GHCR_PREFIX}/ateapi:${SUBSTRATE_TAG}"
  "${GHCR_PREFIX}/atecontroller:${SUBSTRATE_TAG}"
  "${GHCR_PREFIX}/atelet:${SUBSTRATE_TAG}"
  "${GHCR_PREFIX}/kubernetes-secrets:${SUBSTRATE_TAG}"
  "${GHCR_PREFIX}/objectstore-plugin:${SUBSTRATE_TAG}"
  "${GHCR_PREFIX}/podcertcontroller:${SUBSTRATE_TAG}"
)

log()  { printf '\033[1;34m[prepare]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 0. 前置检查 ───────────────────────────────────────────────────────────────
command -v kind    >/dev/null || die "未找到 kind"
command -v kubectl >/dev/null || die "未找到 kubectl"
command -v docker  >/dev/null || die "未找到 docker"

if ! kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
  die "kind 集群 '${KIND_CLUSTER_NAME}' 不存在。先跑：make create-kind-cluster"
fi
docker inspect "${KIND_NODE}" >/dev/null 2>&1 || die "找不到 kind 节点容器 '${KIND_NODE}'"

# ── 1. 准备 ~/.kube/config（坑 3：不存在会让 use-kind-cluster 的 chmod 失败）──
log "准备 ~/.kube/config ..."
mkdir -p "${HOME}/.kube"
if [ ! -f "${HOME}/.kube/config" ]; then
  kind get kubeconfig --name "${KIND_CLUSTER_NAME}" > "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  log "  已创建 ~/.kube/config (600)"
else
  log "  ~/.kube/config 已存在，跳过"
fi

# ── 2. 预拉镜像进 kind 节点（crictl pull，幂等）───────────────────────────────
pull() {
  local img="$1"
  log "拉取 ${img}"
  if docker exec "${KIND_NODE}" crictl pull "${img}" >/dev/null 2>&1; then
    log "  OK"
  else
    warn "  失败：${img}（检查网络/镜像源是否可达）"
    return 1
  fi
}

log "预拉被墙/第三方镜像（同 digest 可达源）..."
rc=0
pull "${POSTGRES_IMAGE}"      || rc=1
pull "${RUSTFS_IMAGE}"        || rc=1
pull "${AWSCLI_IMAGE}"        || rc=1
pull "${AGENTGATEWAY_IMAGE}"  || rc=1

log "预拉 substrate / podcert 组件镜像 (ghcr.io)..."
for img in "${GHCR_IMAGES[@]}"; do
  pull "${img}" || rc=1
done

# ── 3. 校验 digest（可选但推荐：确认换源镜像与 chart 钉死的 digest 一致）──────
log "校验节点内镜像清单..."
docker exec "${KIND_NODE}" crictl images 2>/dev/null \
  | grep -E "substrate|postgres|rustfs|aws-cli|agentgateway" \
  | awk '{print "  "$1":"$2}' || warn "  未能列出镜像"

# ── 结语 ─────────────────────────────────────────────────────────────────────
echo
if [ "${rc}" -eq 0 ]; then
  log "环境预备完成 ✅"
else
  warn "部分镜像拉取失败，请检查上面的 [warn] 行后重跑本脚本（幂等）"
fi

cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
接下来手动执行（涉及耗时构建 / 敏感 API key，脚本不代劳）：

  # 1) 构建并推送 6 个组件镜像（受限网络参数）
  make build \
    BUILDX_BUILDER_NAME=desktop-linux \
    EXTRA_BUILD_ARGS="--build-arg GOPROXY=https://goproxy.cn,direct --build-arg GOSUMDB=off"

  # 2) 安装（把 <HAI-KEY> 换成你的 HAI Proxy key；它只进 Secret，不落文件）
  OPENAI_API_KEY='<HAI-KEY>' make kagent-cli-deploy \
    BUILDX_BUILDER_NAME=desktop-linux MODEL_PROVIDER=openAI

  # 3) 打开 dashboard
  kubectl -n kagent port-forward svc/kagent-ui 8080:8080
  open http://localhost:8080/

HAI Proxy 正确配置（已写入 helm/kagent/values.yaml）：
  baseUrl   = http://host.docker.internal:6655/litellm/v1
  apiFormat = chatCompletions
  model     = gpt-5.5
────────────────────────────────────────────────────────────────────────────
EOF
