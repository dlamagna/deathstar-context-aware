#!/bin/bash
set -e

# === CONFIGURATION ===
REPO_URL="https://github.com/delimitrou/DeathStarBench.git"
PR_BRANCH="pr-352"
BASE_DIR="$HOME/DeathStarBench"
#CHART_DIR="$BASE_DIR/socialNetwork/helm-chart"

# ======================

# 1. Clone the original repo if it doesn't exist
if [ ! -d "$BASE_DIR" ]; then
  echo "📥 Cloning DeathStarBench repository..."
  git clone "$REPO_URL" "$BASE_DIR"
fi

cd "$BASE_DIR"

echo "🔄 Applying Pull Request #352..."
cd ~/DeathStarBench
git reset --hard HEAD
git clean -fd
git checkout master
git pull origin master
git fetch origin pull/352/head:pr-352
git checkout pr-352
echo "✅ Pull Request #352 applied."

# 2. Initialize submodules
echo "🔄 Updating submodules..."
git submodule update --init --recursive

#FORK_LOADER_URL="https://github.com/bserracanta/DeathStarBench.git"
#LOADER_TARGET="$BASE_DIR/socialNetwork/loader"
# NO LONGER NEEDED SINCE USING K6 NOW
# 3. Download custom loader from fork
# echo "📦 Replacing loader folder from fork..."
# rm -rf "$LOADER_TARGET"
# git clone --depth=1 --branch $PR_BRANCH "$FORK_LOADER_URL" temp_loader_repo
# cp -r temp_loader_repo/socialNetwork/loader "$LOADER_TARGET"
# rm -rf temp_loader_repo

# 3b. Fix init container URL: helm chart uses fork 'dimoibiehg' which lacks keys/lua scripts
echo "🔧 Fixing init container URLs (dimoibiehg → delimitrou)..."
find "$BASE_DIR/socialNetwork/helm-chart" -name "values.yaml" \
  -exec sed -i 's|dimoibiehg/DeathStarBench|delimitrou/DeathStarBench|g' {} \;
echo "✅ Init container URLs fixed."

# 4. Deploy Social Network app using Helm
echo "📦 Deploying Social Network using Helm..."
cd "$BASE_DIR/socialNetwork"
helm install social-network ./helm-chart/socialnetwork -n socialnetwork
echo "✅ DeathStarBench reinstalled."

# 5. Wait for pods to be ready (non-fatal: NodePort patch must always run)
echo "⏳ Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod --all -n socialnetwork --timeout=300s || true

echo "Exposing Nginx as NodePort..."
kubectl patch svc nginx-thrift -n socialnetwork -p '{"spec": {"type": "NodePort"}}'
echo "✅ Nginx exposed as NodePort."

# 6. Output end message
echo "✅ Social Network deployed in namespace 'socialnetwork'."

# 7. Build WRK2 in the Correct Directory
    # sudo apt install libssl-dev (previous requirement)
    # sudo apt install zlib1g-dev
    # sudo apt-get install luarocks
    # sudo luarocks install luasocket
# echo "⚙️ Building WRK2..."
# cd "$BASE_DIR/wrk2/"
# make
# echo "✅ WRK2 built successfully."
