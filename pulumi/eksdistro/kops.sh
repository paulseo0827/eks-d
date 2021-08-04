#!/usr/bin/env bash

if [ -z "$CLUSTER_NAME" ]; then
    echo "Cluster name must be an FQDN: <yourcluster>.yourdomain.com or <yourcluster>.sub.yourdomain.com"
    read -r -p "What is the name of your Cluster? " CLUSTER_NAME
fi

export CNI_VERSION_URL=https://distro.eks.amazonaws.com/kubernetes-1-21/releases/1/artifacts/plugins/v0.8.7/cni-plugins-linux-amd64-v0.8.7.tar.gz
export CNI_ASSET_HASH_STRING=sha256:bd6c701deb6624894e22339a0c645a60935ed06a2f071d61b0b1aed8d04b9550

# Create a unique s3 bucket name, or use an existing S3_BUCKET environment variable
export S3_BUCKET=${S3_BUCKET:-"kops-state-store-$(cat /dev/random | LC_ALL=C tr -dc "[:alpha:]" | tr '[:upper:]' '[:lower:]' | head -c 32)"}
export KOPS_STATE_STORE=s3://$S3_BUCKET
echo "Using S3 bucket $S3_BUCKET: to use with kops run"
echo
echo "    export KOPS_STATE_STORE=s3://$S3_BUCKET"
echo "    export CNI_VERSION_URL=$CNI_VERSION_URL"
echo "    export CNI_ASSET_HASH_STRING=$CNI_ASSET_HASH_STRING"
echo

# Create the bucket if it doesn't exist
_bucket_name=$(aws s3api list-buckets  --query "Buckets[?Name=='$S3_BUCKET'].Name | [0]" --out text)
if [ $_bucket_name == "None" ]; then
    echo "Creating S3 bucket: $S3_BUCKET"
    if [ "$AWS_DEFAULT_REGION" == "ap-northeast-2" ]; then
        aws s3api create-bucket --bucket $S3_BUCKET
    else
        aws s3api create-bucket --bucket $S3_BUCKET --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION
    fi
fi

kops create cluster $CLUSTER_NAME \
    --zones "ap-northeast-2a,ap-northeast-2b,ap-northeast-2c" \
    --master-zones "ap-northeast-2a" \
    --networking kubenet \
    --node-count 3 \
    --node-size m5.xlarge \
    --kubernetes-version https://distro.eks.amazonaws.com/kubernetes-1-21/releases/1/artifacts/kubernetes/v1.21.2 \
    --master-size m5.large \
    --dry-run \
    -o yaml > $CLUSTER_NAME.yaml
echo "Add the following content to your Cluster spec in $CLUSTER_NAME.yaml"
echo
cat << EOF >> /dev/stdout
  kubeAPIServer:
    image: public.ecr.aws/eks-distro/kubernetes/kube-apiserver:v1.21.2-eks-1-21-1
  kubeControllerManager:
    image: public.ecr.aws/eks-distro/kubernetes/kube-controller-manager:v1.21.2-eks-1-21-1
  kubeScheduler:
    image: public.ecr.aws/eks-distro/kubernetes/kube-scheduler:v1.21.2-eks-1-21-1
  kubeProxy:
    image: public.ecr.aws/eks-distro/kubernetes/kube-proxy:v1.21.2-eks-1-21-1
  # Metrics Server will be supported with kops 1.19
  metricsServer:
    enabled: true
    insecure: true
    image: public.ecr.aws/eks-distro/kubernetes-sigs/metrics-server:v0.5.0-eks-1-21-1
  authentication:
    aws:
      image: public.ecr.aws/eks-distro/kubernetes-sigs/aws-iam-authenticator:v0.5.2-eks-1-21-1
  kubeDNS:
    provider: CoreDNS
    coreDNSImage: public.ecr.aws/eks-distro/coredns/coredns:v1.8.3-eks-1-21-1
    externalCoreFile: |
      .:53 {
          errors
          health {
            lameduck 5s
          }
          kubernetes cluster.local. in-addr.arpa ip6.arpa {
            pods insecure
            #upstream
            fallthrough in-addr.arpa ip6.arpa
          }
          prometheus :9153
          forward . /etc/resolv.conf
          loop
          cache 30
          loadbalance
          reload
      }
  masterKubelet:
    podInfraContainerImage: public.ecr.aws/eks-distro/kubernetes/pause:v1.21.2-eks-1-21-1
  # kubelet might already be defined, append the following config
  kubelet:
    podInfraContainerImage: public.ecr.aws/eks-distro/kubernetes/pause:v1.21.2-eks-1-21-1
EOF
