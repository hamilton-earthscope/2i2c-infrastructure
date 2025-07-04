local cluster_name = std.extVar('2I2C_VARS.CLUSTER_NAME');

local makePVCApproachingFullAlert = function(
  name,
  summary,
  persistentvolumeclaim,
                                    ) {
  // Structure is documented in https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
  name: name,
  rules: [
    {
      alert: name,
      expr: |||
        # We use min() here for two reasons:
        # 1. kubelet_volume_stats_* is reported once per each node the PVC is mounted on, which can be
        #    multiple nodes if the PVC is ReadWriteMany (like any NFS mount). We only want alerts once per
        #    PVC, rather than once per node.
        # 2. This metric has a *ton* of labels, that can be cluttering and hard to use on pagerduty. We use
        #    min() to select only the labels we care about, which is the namespace it is on.
        #
        # We could have used any aggregating function, but use min because we expect the numbers on the
        # PVC to be the same on all nodes.
        min(kubelet_volume_stats_available_bytes{persistentvolumeclaim='%s'}) by (namespace)
        /
        min(kubelet_volume_stats_capacity_bytes{persistentvolumeclaim='%s'}) by (namespace)
        < 0.1
      ||| % [persistentvolumeclaim, persistentvolumeclaim],
      'for': '5m',
      labels: {
        cluster: cluster_name,
      },
      annotations: {
        summary: summary,
      },
    },
  ],
};

local makePodRestartAlert = function(
  name,
  summary,
  pod_name_substring,
                            ) {
  name: name,
  rules: [
    {
      alert: name,
      expr: |||
        # Count total container restarts with pod name containing 'pod_name_substring'.
        kube_pod_container_status_restarts_total{pod=~'.*%s.*'} >= 1
      ||| % [pod_name_substring],
      'for': '5m',
      labels: {
        cluster: cluster_name,
      },
      annotations: {
        summary: summary,
      },
    },
  ],
};

{
  prometheus: {
    alertmanager: {
      enabled: true,
      config: {
        route: {
          group_wait: '10s',
          group_interval: '5m',
          receiver: 'pagerduty',
          repeat_interval: '3h',
          routes: [
            {
              receiver: 'pagerduty',
              matchers: [
                // We want to match all alerts, but not add additional labels as they
                // clutter the view. So we look for the presence of the 'cluster' label, as that
                // is present on all alerts we have. This makes the 'cluster' label *required* for
                // all alerts if they need to come to pagerduty.
                'cluster =~ .*',
              ],
            },
          ],
        },
      },
    },
    serverFiles: {
      'alerting_rules.yml': {
        groups: [
          makePVCApproachingFullAlert(
            'HomeDirectoryDiskApproachingFull',
            'Home Directory Disk about to be full: cluster:%s hub:{{ $labels.namespace }}' % [cluster_name],
            'home-nfs',
          ),
          makePVCApproachingFullAlert(
            'HubDatabaseDiskApproachingFull',
            'Hub Database Disk about to be full: cluster:%s hub:{{ $labels.namespace }}' % [cluster_name],
            'hub-db-dir',
          ),
          makePVCApproachingFullAlert(
            'PrometheusDiskApproachingFull',
            'Prometheus Disk about to be full: cluster:%s' % [cluster_name],
            'support-prometheus-server',
          ),
          makePodRestartAlert(
            'GroupsExporterPodRestarted',
            'jupyterhub-groups-exporter pod has restarted on %s:{{ $labels.namespace }}' % [cluster_name],
            'groups-exporter',
          ),
        ],
      },
    },
  },
}
