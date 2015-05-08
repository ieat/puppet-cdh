# == Class cdh::spark
# Installs spark set up to work in YARN mode.
# You should include this on your client nodes.
# This does not need to be on all worker nodes.
#
# == Parameters
# $hive_support_enabled     - If true, Hive jars will be automatically loaded
#                             into Spark's classpath, and hive-site.xml will
#                             be symlinked into /etc/spark/conf and cdh::hive
#                             will be added as a dependency.  Default: true
#
# $master_host              - If set, Spark will be configured to work in standalone mode,
#                             rather than in YARN.  Include cdh::spark::master on this host
#                             and cdh::spark::worker on all standalone Spark Worker nodes.
#                             Default: undef
#
# $worker_cores             - Number of cores to allocate per spark worker.
#                             This is only used in standalone mode.  Default: $::processorcount
#
# $worker_memory            - Total amount of memory workers are allowed to use on a node.
#                             This is only used in standalone mode.  Default:  "${::memorysize_mb - 1024}m",
#
# $worker_instances         - Number of worker instances to run on a node.  Note that $worker_cores
#                             will apply to each worker.  If you increase this, make sure to
#                             make $worker_cores smaller appropriately.
#                             This is only used in standalone mode.  Default: 1
#
# $daemon_memory            - Memory to allocate to the Spark master and worker daemons themselves.
#                             This is only used in standalone mode.  Default: 512m
#
class cdh::spark(
    $hive_support_enabled   = true,
    $master_host            = undef,
    $worker_cores           = $::processorcount,
    $worker_memory          = "${::memorysize_mb - 1024}m",
    $worker_instances       = 1,
    $daemon_memory          = '512m',
)
{
    # Spark requires Hadoop configs installed.
    Class['cdh::hadoop'] -> Class['cdh::spark']

    # If we are using Hive, then require cdh::hive
    if $hive_support_enabled {
        Class['cdh::hive'] -> Class['cdh::spark']
    }

    # If $standalone_master_host was set,
    # then we will be configuring a standalone spark cluster.
    $standalone_enabled = $master_host ? {
        undef   => false,
        default => true,
    }

    package { ['spark-core', 'spark-python']:
        ensure => 'installed',
    }

    $config_directory = "/etc/spark/conf.${cdh::hadoop::cluster_name}"
    # Create the $cluster_name based $config_directory.
    file { $config_directory:
        ensure  => 'directory',
        require => Package['spark-core'],
    }
    cdh::alternative { 'spark-conf':
        link    => '/etc/spark/conf',
        path    => $config_directory,
    }

    # Only need to ensure these directories once.
    # TODO: In default YARN mode, how to make sure we only check these directories from one puppet host?
    if !$standalone_enabled or $standalone_master_host == $::fqdn {
        # sudo -u hdfs hdfs dfs -mkdir /user/spark
        # sudo -u hdfs hdfs dfs -chmod 0775 /user/spark
        # sudo -u hdfs hdfs dfs -chown spark:spark /user/spark
        cdh::hadoop::directory { '/user/spark':
            owner   => 'spark',
            group   => 'spark',
            mode    => '0755',
            require => Package['spark-core'],
        }

        cdh::hadoop::directory { '/user/spark/share':
            owner   => 'spark',
            group   => 'spark',
            mode    => '0755',
            require => Cdh::Hadoop::Directory['/user/spark'],

        }
        cdh::hadoop::directory { '/user/spark/share/lib':
            owner   => 'spark',
            group   => 'spark',
            mode    => '0755',
            require => Cdh::Hadoop::Directory['/user/spark/share'],
        }

        cdh::hadoop::directory { ['/user/spark/applicationHistory']:
            owner   => 'spark',
            group   => 'spark',
            mode    => '1777',
            require => Cdh::Hadoop::Directory['/user/spark'],
        }
    }

    $namenode_address = $::cdh::hadoop::ha_enabled ? {
        true    => $cdh::hadoop::nameservice_id,
        default => $cdh::hadoop::primary_namenode_host,
    }

    if !$standalone_enabled {
        # Put Spark assembly jar into HDFS so that it d
        # doesn't have to be loaded for each spark job submission.

        $spark_jar_hdfs_path = "hdfs://${namenode_address}/user/spark/share/lib/spark-assembly.jar"
        exec { 'spark_assembly_jar_install':
            command => "/usr/bin/hdfs dfs -put -f /usr/lib/spark/lib/spark-assembly.jar ${spark_jar_hdfs_path}",
            unless  => '/usr/bin/hdfs dfs -ls /user/spark/share/lib/spark-assembly.jar | grep -q /user/spark/share/lib/spark-assembly.jar',
            user    => 'spark',
            require => Cdh::Hadoop::Directory['/user/spark/share/lib'],
            before  => [
                File["${config_directory}/spark-env.sh"],
                File["${config_directory}/spark-defaults.conf"]
            ],
        }
    }

    file { "${config_directory}/spark-env.sh":
        content => template('cdh/spark/spark-env.sh.erb'),
    }

    file { "${config_directory}/spark-defaults.conf":
        content => template('cdh/spark/spark-defaults.conf.erb'),
    }

    file { "${config_directory}/log4j.properties":
        source => 'puppet:///modules/cdh/spark/log4j.properties',
    }

    $hive_site_symlink_ensure = $hive_support_enabled ? {
        true    => 'link',
        default => 'absent'
    }
    # If Hive support is enabled, then symlink hive-site.xml into /etc/spark/conf
    file { "${config_directory}/hive-site.xml":
        ensure => $hive_site_symlink_ensure,
        target => "${::cdh::hive::config_directory}/hive-site.xml",
    }
}