# Reproducible shim build for the linux-hardened project.
#
# Output: shimx64.efi, mmx64.efi, BOOTX64.CSV.
#
# The build embeds our project vendor certificate (the public half of
# the kernel/module signing key). Microsoft signing happens at the
# Hardware Dev Center *after* shim-review approval, against this exact
# binary.
#
# Shim-review requires that this build be byte-reproducible from this
# Dockerfile alone. Do not modify after submission without updating
# the submission record at shim/submission/.

# TODO: pin a concrete debian:trixie digest before building for
# submission, and record it in shim/submission/build-metadata.json.
FROM debian:trixie@sha256:REPLACE_WITH_CONCRETE_DIGEST

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        gnu-efi \
        efitools \
        libefivar-dev \
        libpopt-dev \
        libssl-dev \
        openssl \
        ca-certificates \
        wget \
        pesign \
    && rm -rf /var/lib/apt/lists/*

# Pin shim source by exact tag. Update only with shim-review reapproval.
ARG SHIM_VERSION=15.8
RUN git clone --depth 1 --branch ${SHIM_VERSION} \
    https://github.com/rhboot/shim.git /shim \
    && cd /shim && git submodule update --init --recursive

WORKDIR /shim

# NOTE: This Dockerfile is currently inert. The project signs with a
# Forgejo-resident key; the shim-review board
# requires an HSM-backed key, so submission and Microsoft signing are
# blocked. If that gate ever clears, regenerate vendor.der as the DER
# form of the HSM-resident signing cert and place it next to this
# Dockerfile. The COPY below will then succeed.
COPY vendor.der /shim/vendor.der

# Reproducibility: pin the build timestamp via SOURCE_DATE_EPOCH and
# fix the user/host that get embedded into build artifacts.
ARG SOURCE_DATE_EPOCH=1700000000
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    KBUILD_BUILD_USER=hardened \
    KBUILD_BUILD_HOST=builder

RUN make VENDOR_CERT_FILE=/shim/vendor.der \
    && ls -la shimx64.efi mmx64.efi BOOTX64.CSV \
    && sha256sum shimx64.efi mmx64.efi BOOTX64.CSV
