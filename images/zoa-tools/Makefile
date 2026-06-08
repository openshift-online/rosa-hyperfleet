IMAGE_REPO ?= quay.io/slopezz/zoa-tools
IMAGE_TAG ?= latest
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || echo docker)

.PHONY: build push

build:
	$(CONTAINER_RUNTIME) build --platform linux/amd64 -t $(IMAGE_REPO):$(IMAGE_TAG) .

push: build
	$(CONTAINER_RUNTIME) push $(IMAGE_REPO):$(IMAGE_TAG)
