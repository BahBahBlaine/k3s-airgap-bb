#!/usr/bin/env bash

set -e
set -o nounset
set -o pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# cd to the same dir this script is in for relative paths to work properly
cd $SCRIPT_DIR


architecture=amd64
artifact_dir="/opt/artifacts"
k3s_version=""
rke2_version=""
ironbank_rke2=false
# Create a new images file by running the following command on a currently running cluster
# for i in $(kubectl get pods --all-namespaces -o jsonpath="{.items[*].spec.containers[*].image}"); do echo $i ; done | sort | uniq > images-new.txt

images_to_download_list_file=images.txt

while getopts b:k:r:id:u:p: flag
do
    case "${flag}" in
        a) architecture=${OPTARG};;
        b) bigbang_version=${OPTARG};;
        k) k3s_version=${OPTARG};;
        r) rke2_version=${OPTARG};;
        d) images_to_download_list_file=${OPTARG};;
        u) registry1_user=${OPTARG};;
        p) registry1_pass=${OPTARG};;
    esac
done

if ! [ $(id -u) = 0 ]; then
   echo "This script must be run as root"
   exit 1
fi

if [[ -z "$bigbang_version" ]] ; then
  echo "You must specify the Big Bang version with the -b flag (i.e. 1.15.2)"
  exit 1
fi

if [[ -z "$k3s_version" && -z "$rke2_version" ]] ; then
  echo "You must specify the k3s version with the -k flag (i.e. v1.21.4+k3s1) or the rke2 version with flag -r (i.e. v1.21.5+rke2r2)"
  exit 1
fi

if [[ ! -z "$k3s_version" && ! -z "$rke2_version" ]] ; then
  echo "Please specify either -k or -r , but not both"
  exit 1
fi


crictl=/usr/local/bin/crictl
crictl_args=""
ctr=/usr/local/bin/ctr
ctr_args=""
kubectl=/usr/local/bin/kubectl
kubectl_args=""

# Get IronBank Credentials
if [[ -z "$registry1_user" ]] ; then
  echo "You must specify the registry1 (ironbank) username with the -u flag (i.e. First_Last)"
  exit 1
fi


# Download k3s artifacts
grabK3S () {
    # download k3s binary
    curl -L https://github.com/k3s-io/k3s/releases/download/${k3s_version}/k3s --output ${artifact_dir}/k3s
    chmod +x ${artifact_dir}/k3s

    # download k3s airgap images
    images_tar=${artifact_dir}/k3s-airgap-images-${architecture}.tar
    curl -L https://github.com/k3s-io/k3s/releases/download/${k3s_version}/k3s-airgap-images-${architecture}.tar --output ${images_tar} -z ${images_tar}

    # download k3s rpms
    curl -L https://rpm.rancher.io/k3s/latest/common/centos/8/noarch/k3s-selinux-0.2-1.el7_8.noarch.rpm --output ${images_tar} -z ${images_tar}

    # Download k3s installation script
    curl -L https://get.k3s.io --output ${artifact_dir}/k3s-install.sh -z ${artifact_dir}/k3s-install.sh
    chmod +x ${artifact_dir}/k3s-install.sh

    # Run k3s for cri utilities
    curl -sfL https://get.k3s.io | sh -
}


# Download rke2 artifacts
# For now to make things easier, we install the public docker images and then use ironbank if requested for the deploy_rke2.sh
grabRke2 () {
    # Download rke2 airgap images
    image_zst=${artifact_dir}/rke2-images.linux-${architecture}.tar.zst
    curl -L https://github.com/rancher/rke2/releases/download/${rke2_version}/rke2-images.linux-${architecture}.tar.zst --output $image_zst -z $image_zst

    # download k3s binary
    image_targz=${artifact_dir}/rke2.linux-${architecture}.tar.gz
    curl -L https://github.com/rancher/rke2/releases/download/${rke2_version}/rke2.linux-${architecture}.tar.gz --output $image_targz -z $image_targz

    # Download checksums to verify proper downloads sha256sum-${architecture}.
    shasums=${artifact_dir}/sha256sum-${architecture}.txt
    curl -L https://github.com/rancher/rke2/releases/download/${rke2_version}/sha256sum-${architecture}.txt --output $shasums -z $shasums

    install_sh=${artifact_dir}/rke2-install.sh
    curl -L https://get.rke2.io --output ${install_sh} -z $install_sh

    INSTALL_RKE2_ARTIFACT_PATH=${artifact_dir} sh ${install_sh}

    systemctl enable rke2-server
    systemctl start rke2-server
}

# Download IronBank images
grabImages () {
    until sudo $crictl $crictl_args info -q | grep RuntimeReady
    do
        sleep 5
    done

    while read imageUrl; do
        imageName=$(echo $imageUrl | cut -d '|' -f 1)
        imageTags=$(echo $imageUrl | tr '|'  ' ') # tags includes name
        creds=""
        if [[ "$imageName" == *"registry1.dso.mil"* ]]; then
            creds=" -u $registry1_user:$registry1_pass "
        fi
        $ctr $ctr_args image pull $creds ${imageName}

        while IFS='|' read -ra tags; do
            for tag in "${tags[@]}"; do
                if [[ "$tag" != "$imageName" ]]; then
                    $ctr $ctr_args image tag --force $imageName $tag
                fi
            done
        done <<< "$imageUrl"

        $ctr $ctr_args image export ${artifact_dir}/images/$(echo ${imageUrl} |sed 's/\//-/g' |sed 's/\:/-/g').tar ${imageTags}
    done <$images_to_download_list_file
}

# Get Big Bang artifacts

grabBB () {

    # Download bigbang repository
    bigbang_tar=${artifact_dir}/bigbang\-${bigbang_version}.tar.gz
    curl -L https://repo1.dso.mil/platform-one/big\-bang/bigbang/\-/archive/${bigbang_version}/bigbang\-${bigbang_version}.tar.gz --output $bigbang_tar -z $bigbang_tar
    tar -xz -C ${artifact_dir}/ -f $bigbang_tar
    tar -czvf ${artifact_dir}/bigbang-${bigbang_version}.tgz -C ${artifact_dir}/bigbang-${bigbang_version}/chart/ .

    # Download Big Bang repos
    repo_tar=${artifact_dir}/repositories.tar.gz
    curl -L https://umbrella-bigbang-releases.s3-us-gov-west-1.amazonaws.com/umbrella/${bigbang_version}/repositories.tar.gz --output $repo_tar -z $repo_tar
    tar -xz -C ${artifact_dir}/git/ -f $repo_tar

    # Istio version workaround
    #git --git-dir=${artifact_dir}/git/repos/istio-controlplane/.git reset HEAD --hard
    #git --git-dir=${artifact_dir}/git/repos/istio-controlplane/.git checkout tags/1.9.8-bb.0

    # copy flux manifest

    $kubectl $kubectl_args kustomize /opt/artifacts/bigbang-${bigbang_version}/base/flux -o ${artifact_dir}/flux.yaml

    # get local git repo image

    $ctr $ctr_args image pull docker.io/bgulla/git-http-backend:latest
    $ctr $ctr_args image export ${artifact_dir}/images/git-http-backend.tar docker.io/bgulla/git-http-backend:latest

}

osDeps () {

    # install utilities needed by download script

    yum install git yum-utils -y

    # download pre-req RPMs

    mkdir -p ${artifact_dir}/rpms
    yumdownloader --resolve --destdir=${artifact_dir}/rpms/ container-selinux selinux-policy-base iscsi-initiator-utils rsync

    # copy deployment scripts
    cp -rf destination-scripts ${artifact_dir}/deploy

}

main () {
    # Create necessary directories
    mkdir -p ${artifact_dir} ${artifact_dir}/images ${artifact_dir}/git ${artifact_dir}/rpms

    # Copy git-http-backend manifests to artifact dir
    cp -rf artifacts/git-http-backend ${artifact_dir}/git-http-backend


    if [[ -n "${k3s_version}" ]] ; then
        grabK3S
    elif [[ -n "${rke2_version}" ]]; then
        grabRke2
        crictl=$(find /var/lib/rancher/rke2/data -name crictl -print -quit)
        crictl_args="--config $(find /var/lib/rancher/rke2 -name crictl.yaml)"
        ctr=$(find /var/lib/rancher/rke2/data -name ctr -print -quit)
        address=$(find /var/lib/rancher/rke2 -name crictl.yaml | xargs cat | grep runtime-endpoint | cut -d ' ' -f 2 | cut -d '/' -f 3-)
        ctr_args="--address ${address}"
        kubectl=$(find /var/lib/rancher/rke2/data -name kubectl -print -quit )
        kubectl_args="--kubeconfig /etc/rancher/rke2/rke2.yaml"
    else
        echo "something went wrong"
        exit 1
    fi
    grabImages
    grabBB
    osDeps

    # package it all up nice and tidy
    tar -czvf ~/artifacts-airgap.tar.gz ${artifact_dir}
}

main
