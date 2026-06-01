#!/bin/bash
# You Release Image Push Script
# Usage: ./push-release.sh [tag]
# Set MULTIARCH=true for multi-arch builds (requires buildx)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="bonney:3000"
REGISTRY_USER="mandax"
IMAGE_NAME="you"
TAG="${1:-latest}"
MULTIARCH="${MULTIARCH:-false}"
NO_CACHE="${NO_CACHE:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check for Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker not found. Please install Docker first."
        exit 1
    fi
    log_success "Docker found"
}

# Build and push image
build_and_push() {
    local full_tag="${REGISTRY}/${REGISTRY_USER}/${IMAGE_NAME}:${TAG}"

    if [ "${MULTIARCH}" = "true" ]; then
        build_and_push_multiarch "${full_tag}"
    else
        build_and_push_simple "${full_tag}"
    fi
}

# Simple build (default, works everywhere including Gitea runner)
build_and_push_simple() {
    local full_tag="$1"
    log_info "Building release image (single arch)..."
    log_info "Image tag: ${full_tag}"

    docker build \
        --tag "${full_tag}" \
        --file "${SCRIPT_DIR}/Dockerfile" \
        "${SCRIPT_DIR}"

    log_success "Image built. Pushing..."
    docker push "${full_tag}"
    log_success "Image pushed: ${full_tag}"
}

# Multi-arch build (requires buildx, for dev machines)
build_and_push_multiarch() {
    local full_tag="$1"
    local platforms="${PLATFORMS:-linux/amd64,linux/arm64}"

    if ! docker buildx version &>/dev/null; then
        log_error "Docker buildx not available."
        exit 1
    fi

    local builder="multiarch"
    if ! docker buildx inspect "$builder" &>/dev/null; then
        log_info "Creating buildx builder: $builder"
        docker buildx create --name "$builder" --use
    else
        docker buildx use "$builder"
    fi
    docker buildx inspect --bootstrap
    log_success "Buildx ready: ${platforms}"

    log_info "Building multi-arch release image..."
    log_info "Image tag: ${full_tag}"
    log_info "Platforms: ${platforms}"

    local cache_args=()
    if [ "${NO_CACHE}" = "true" ]; then
        cache_args+=("--no-cache")
        log_info "Forcing full rebuild"
    fi

    docker buildx build \
        "${cache_args[@]}" \
        --platform "${platforms}" \
        --tag "${full_tag}" \
        --file "${SCRIPT_DIR}/Dockerfile" \
        --push \
        "${SCRIPT_DIR}"

    log_success "Multi-arch image pushed: ${full_tag}"
}

# Display image info
display_info() {
    local full_tag="${REGISTRY}/${REGISTRY_USER}/${IMAGE_NAME}:${TAG}"

    echo ""
    echo "=============================================="
    echo -e "  ${GREEN}You Release Image${NC}"
    echo "=============================================="
    echo "  Image: ${full_tag}"
    echo "  Registry: ${REGISTRY}"
    echo "  User: ${REGISTRY_USER}"
    echo "  Tag: ${TAG}"
    echo ""
    echo "  Pull command:"
    echo "  docker pull ${full_tag}"
    echo ""
    echo "  Run command:"
    echo "  docker run -d \\"
    echo "    -e DATABASE_PATH=/data/you/prod.db \\"
    echo "    -e SECRET_KEY_BASE=\$(mix phx.gen.secret) \\"
    echo "    -e PHX_HOST=you.example.com \\"
    echo "    -v you-data:/data/you \\"
    echo "    -p 4000:4000 \\"
    echo "    ${full_tag}"
    echo "=============================================="
    echo ""
}

# Main execution
main() {
    cd "$SCRIPT_DIR"

    log_info "Starting release image build and push..."

    check_docker
    build_and_push
    display_info

    log_success "Release image pushed successfully!"
}

main
