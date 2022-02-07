bigbang_version=1.15.2

rm /var/lib/rancher/k3s/server/manifests/bigbang.yaml
rm /var/lib/rancher/k3s/server/manifests/flux-deploy.yaml

rm /var/lib/rancher/k3s/server/static/charts/bigbang-${bigbang_version}.tgz

/usr/local/bin/k3s kubectl delete addon bigbang -n kube-system && \
/usr/local/bin/k3s kubectl delete addon flux-deploy -n kube-system && \
/usr/local/bin/k3s kubectl delete helmcharts bigbang -n bigbang && \
systemctl restart k3s

/usr/local/bin/k3s kubectl delete jobs -n bigbang --all && \
/usr/local/bin/k3s kubectl delete helmreleases -A --all && \
/usr/local/bin/k3s kubectl delete pods -n flux-system --all --force --grace-period=0 && \
/usr/local/bin/k3s kubectl delete pods -n istio-operator --all && \
/usr/local/bin/k3s kubectl delete pods -n istio-system --all --force --grace-period=0 && \
/usr/local/bin/k3s kubectl delete pods -n git --all && \
/usr/local/bin/k3s kubectl delete gitrepository -A --all && \
systemctl restart k3s
