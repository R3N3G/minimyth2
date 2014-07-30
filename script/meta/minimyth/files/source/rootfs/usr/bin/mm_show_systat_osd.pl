#!/usr/bin/perl
#
# Writen by Piotr Oniszczuk <warpme@o2.pl>
#
#
# Script provides quick method to use new MythUInotification for
# displaying:
# -Frontend CPU/Sys temps,fans and uptime
# -Remote backend CPU/Sys temps,fans and uptime
# -Current on-going recordings
# -Next 10 recordings.
# It is designed to run on separated or combined FE/BE.
#
# -Calling script without any parameter will notify with current recorders status.
# -Calling it with "frontend_status" will notify with CPU/GPU/Freq/Fan and status
# (CPU load/mem) for list of defined proceses.
# -Calling it with "server_status" will notify with CPU/GPU/Freq/Fan and status
# (CPU load/mem) for list of defined backend proceses.
# -Calling it with "next_recordings" will notify with list of next reordings.
# I have dedicated button on my remote where single press calls script without parameter,
# double calls it with <frontend_status>, triple press calls with <server_status> and quad
# press calls <next_recordings>
#
# Installation:
# Following components are needed for proper script operation:
# -lm_sensors
# -uptime
# -sshd/ssh
# perl:
#   -IO::Socket
#   -LWP::Simple
#   -XML::Simple
#   -Unicode::Normalize
#   -DateTime
#   -DateTime::Format::ISO8601
#
# How it works:
# For CPU/Sys temps,fans and uptime script parses output of "sensors" and "uptime"
# commands.
# For current on-going and next recordings, script parses status XML file
# downloaded from remote BE.
# After parsing desired data script sends XML data structure towards FE via UDP.
#
# Setup:
# 1. FE and BE systems should have installed lm_sesnsors and uptime packages. 
# 2. lm_sensors configuration (usually sensors.conf)
# should provide CPU/SYS temps/fans with following keywords:
# -"CPU Temp" or "core0[1|2|3]
# -"Sys Temp"
# -"CPU Fan"
# -"Sys Fan"
# 3. If setup is with separated FE/BE, then script should be to execute remote shell
# commands on remote BE. For proper opertion in separated FE/BE scenario, remote 
# ssh infrastructure should be correctly setup (in a manner where execution command 
# on remote BE is possible via something like this "/usr/bin/ssh root@<BE_IP> command".
#
#
# CHANGE LOG:
#
# v1.0 (03/08/2013)
# -Initial version
#


# -----Config are BEGIN -------
my $be_ip                 = "192.168.1.254";
my $fe_ip_list            = "127.0.0.1";

my $frontend_proces_list  = "mythfrontend,X";
my $backend_proces_list   = "mythbackend,sasc-ng,mysqld";

my $osd_temps_timeout     = "10";
my $osd_recorders_timeout = "10";
my $osd_nextrec_timeout   = "15";

my $osd_livetv_icon       = "images/mythnotify/livetv.png";
my $osd_recording_icon    = "images/mythnotify/recording.png";
my $osd_temperatures_icon = "images/mythnotify/temps.png";
my $osd_memory_icon       = "images/mythnotify/memory.png";
my $osd_nextrec_icon      = "images/mythnotify/recording.png";

our $server_title_str;
our $frontend_title_str;
our $process_str;
our $cpu_load_str;
our $memory_usage_str;
our $memory_used_str;
our $hardware_str;
our $uptime_str;
our $cpu_freq_str;
our $cpu_load_str;
our $starts_str;
our $ends_str;
our $recorder_id_str;
our $next_recordings_str;
our $tuners_str;
our $all_tuners_idle_str;
our $total_str;
our $till_end_str;
require '/etc/mm_ui_localizations_perl';

my $temps_style           = "";
my $recorders_style       = "tuners";
my $nextrec_style         = "nextrec-small";
my $nextrec_style_big     = "nextrec";

my $remote_shell_cmd      = "/usr/bin/ssh root\@192.168.1.254";

my $nvidia_settings_bin   = "/usr/bin/nvidia-settings";
my $sensors_bin           = "/usr/bin/sensors";
# -----Config are BEGIN -------


my $debug  = 0;
my $debug2 = 0;














use Shell;
use strict;
use warnings;
use IO::Socket;
use LWP::Simple;
use XML::Simple;
use feature 'switch';
use Unicode::Normalize;
use DateTime;
use DateTime::Format::ISO8601;

binmode(STDOUT, ":utf8");
no warnings 'deprecated';

my $action = "";
my $proces_list = "";
my $shell_cmd = "";
my $title = "";
my @notify_list;

if ($ARGV[0]) { $action = $ARGV[0]; }

sub stack_notify {
    my ($title,$origin,$description,$extra,$image,$progress_text,$progress,$timeout,$style,$fe_ip_list) = @_;
    my $msg = "";

    print ("OSD_notify:\n  title=\"$title\"\n  origin=\"$origin\"\n  description=\"$description\"\n  extra=\"$extra\"\n  image=\"$image\"\n  progress_txt=\"$progress_text\"\n  progress=$progress\n  style=\"$style\"\n") if ($debug);

    $msg ="<mythnotification version=\"1\">
            <image>$image</image>
            <text>$title</text>
            <origin>$origin</origin>
            <description>$description</description>
            <extra>$extra</extra>
            <progress_text>$progress_text</progress_text>
            <progress>$progress</progress>
            <timeout>$timeout</timeout>";
    if ($style) { $msg = $msg."
            <style>$style</style>" } $msg = $msg."
        </mythnotification>";

    @notify_list = (@notify_list,$msg);
}

sub sent_notifies_to_all_hosts {
    my @dest_list = ();
    @dest_list = split(/,/, $fe_ip_list);

    for (@dest_list) {
        my $item;

        foreach $item (@notify_list) {
            print ("Sending via UDP:\n $item\n") if ($debug2);
            my $mythnotify_fh = IO::Socket::INET->new(PeerAddr=>$_,Proto=>'udp',PeerPort=>6948);
            if ($mythnotify_fh) {
                print $mythnotify_fh $item;
                $mythnotify_fh->close;
                print ("Notify via OSD to IP=$_ done\n") if ($debug);
            }
        }
    }

    @notify_list = ();
}

sub load_xml {

  my $status = "";
  my $url = "http://$be_ip:6544/Status/xml";

  eval {
    local $SIG{ALRM} = sub { die "alarm\n" };
    alarm(30);
    $status = get($url);
    alarm(0);
  };

  die "Sorry, failed to fetch $url.\n"
      unless defined $status;

  warn "Loaded XML from $be_ip\n"
    if $debug;


  for ( $status ) {
    $_ = NFD( $_ );   ##  decompose
    s/\pM//g;         ##  strip combining characters
    s/[^\0-\x80]//g;  ##  clear everything else
  }

  # bug in early 0.26
  $status =~ s/MythDate::ISODate/Date::ISODate/g;

  print ($status) if $debug2; 

  return $status;

}

sub get_gpu_temp {
    my $out = "-1";
    my ($shell_exec) = @_;

    my $command = $shell_exec." $nvidia_settings_bin --query GPUCoreTemp --terse 2>&1; |";
    if ($debug2) { print "Command get_gpu_temp_command:".$command."\n"; }

    $out = open(SHELL, $command);
    while (<SHELL>) {
        my $res = $_;
        if (($res =~ m/No such file/) || ($res eq ""))  {
            $out="-1";
           }
        else {
           $_ =~ m/([0-9]+)/;
           $out=$1;
        }
    }
    close(SHELL);

    if ($debug2) {
        print "GPU Temp   : $out\n";
    }

    return $out;
}

sub get_cpu_sys_temp_fans {
    my ($shell_exec) = @_;
    my $cpu_temp = "-1";
    my $sys_temp = "-1";
    my $cpu_fan = "-1";
    my $sys_fan = "-1";
    my $cpu__temp = "-1";
    my $core0_temp = "-1";
    my $core1_temp = "-1";
    my $core2_temp = "-1";
    my $core3_temp = "-1";

    if (! -e $sensors_bin) { return $cpu_temp,$sys_temp,$cpu_fan,$sys_fan; }

    my $command = $shell_exec." $sensors_bin 2>/dev/null; |";
    if ($debug2) { print "Command get_cpu_sys_temp_fans:".$command."\n"; }

    my $out = open(SHELL, $command);
    while (<SHELL>) {
        $out = $_;
        if ($out=~/CPU Temp/) {
            $out =~ m/([0-9]+)/;
            $cpu__temp=$1;
        }
        $out = $_;
        if ($out =~ /M\/B Temp/) {
            $out =~ m/([0-9]+)/;
            $sys_temp=$1;
        }
        if ($out =~ /Sys Temp/) {
            $out =~ m/([0-9]+)/;
            $sys_temp=$1;
        }
        $out = $_;
        if ($out =~ /CPU Fan/) {
            $out =~ m/([0-9]+)/;
            $cpu_fan=$1;
        };
        $out = $_;
        if ($out =~ /Sys Fan/) {
            $out =~ m/([0-9]+)/;
            $sys_fan=$1;
        };
        $out = $_;
        if ($out =~ /Core 0/) {
            $out =~ s/Core 0//;
            $out =~ m/([0-9]+)/;
            $core0_temp=$1;
        };
        $out = $_;
        if ($out =~ /Core 1/) {
            $out =~ s/Core 1//;
            $out =~ m/([0-9]+)/;
            $core1_temp=$1;
        };
        $out = $_;
        if ($out =~ /Core 2/) {
            $out =~ s/Core 2//;
            $out =~ m/([0-9]+)/;
            $core2_temp=$1;
        };
        $out = $_;
        if ($out =~ /Core 3/) {
            $out =~ s/Core 3//;
            $out =~ m/([0-9]+)/;
            $core3_temp=$1;
        };
        if ($out=~/CPU1 Temp/) {
            $out =~ s/CPU1 Temp//;
            $out =~ m/([0-9]+)/;
            $core0_temp=$1;
        }
        if ($out=~/CPU2 Temp/) {
            $out =~ s/CPU2 Temp//;
            $out =~ m/([0-9]+)/;
            $core1_temp=$1;
        }
        if ($out=~/temp1/) {
            $out =~ s/temp1//;
            $out =~ m/([0-9]+)/;
            $core0_temp=$1;
        }
        if ($out=~/temp2/) {
            $out =~ s/temp2//;
            $out =~ m/([0-9]+)/;
            $core1_temp=$1;
        }
    }
    close(SHELL);

    if ($core0_temp != -1) { 
        $cpu_temp = $core0_temp;
        if ($core1_temp != -1) { $cpu_temp = $cpu_temp."/".$core1_temp; }
        if ($core2_temp != -1) { $cpu_temp = $cpu_temp."/".$core2_temp; }
        if ($core3_temp != -1) { $cpu_temp = $cpu_temp."/".$core3_temp; }
    }
    else {
        if ($cpu__temp != -1) { $cpu_temp = $cpu__temp; }
    }

    if ($debug2) {
        print "CPU Temp   : $cpu_temp\n";
        print "Sys Temp   : $sys_temp\n";
        print "CPU fan    : $cpu_fan\n";
        print "Sys fan    : $sys_fan\n";
        print "Core0 Temp : $core0_temp\n";
        print "Core1 Temp : $core1_temp\n";
        print "Core2 Temp : $core2_temp\n";
        print "Core3 Temp : $core3_temp\n";
    }

    return $cpu_temp,$sys_temp,$cpu_fan,$sys_fan;
}

sub get_cpu_info {
    my ($shell_exec) = @_;
    my $cpu_family="-1";
    my $cpu_model="-1";
    my $cpu_name="-1";
    my $cpu_freq="";
    my $command = $shell_exec." cat /proc/cpuinfo 2>/dev/null; |";

    if ($debug2) { print "Command get_cpu_info_command:".$command."\n"; }

    my $out = open(SHELL, $command);
    while (<SHELL>) {

        $out = $_;
        if ($out =~ /cpu family\s*:/) {
            $out =~ m/([0-9]+)/;
            $cpu_family=$1;
        };
        $out = $_;
        if ($out =~ /model\s*:/) {
            $out =~ m/([0-9]+)/;
            $cpu_model=$1;
        };
        $out = $_;
        if ($out =~ /model name\s*:/) {
            $out =~ m/: (.*)/;
            $cpu_name=$1;
        };
        if ($out =~ /cpu MHz\s*:/) {
            $out =~ m/([0-9]+)/;
            $cpu_freq=$cpu_freq.$1."/";
        };
    }
    close(SHELL);

    $cpu_freq =~ s/\/$//;

    if ($debug2) {
        print "CPU Familly is : $cpu_family\n";
        print "CPU Model is   : $cpu_model\n";
        print "CPU Name  is   : $cpu_name\n";
        print "CPU Freq. is   : $cpu_freq\n";
    }

    return $cpu_family,$cpu_model,$cpu_name,$cpu_freq;
}


sub get_cpu_load {
    my ($shell_exec) = @_;
    my $cpu_load = "";
    my $cpu_user = "";
    my $cpu_system = "";
    my $cpu_nice = "" ;
    my $cpu_idle = "";
    my $cpu_user_single = 0;
    my $cpu_system_single = 0;
    my $cpu_nice_single = 0;
    my $cpu_idle_single = 0;
    my $cpu_count = 0;
    my $command = $shell_exec." top -b -i -n1 | grep Cpu 2>/dev/null; |";

    if ($debug2) { print "Command get_cpu_load_command:".$command."\n"; }

    my $out = open(SHELL, $command);

    while (<SHELL>) {

        $_ =~ s/\%//g;
        $_ =~ s/\s*//g;

        $out = $_;
        $out =~ m/Cpu[0-9]\:(\S*)us,.*/;
        $cpu_user = $cpu_user.$1."/";
        $cpu_user_single = $cpu_user_single + $1;

        $out = $_;
        $out =~ m/us,(\S*)sy,.*/;
        $cpu_system = $cpu_system.$1."/";
        $cpu_system_single = $cpu_system_single + $1;

        $out = $_;
        $out =~ m/sy,(\S*)ni,.*/;
        $cpu_nice = $cpu_nice.$1."/";
        $cpu_nice_single = $cpu_nice_single + $1;

        $out = $_;
        $out =~ m/ni,(\S*)id,.*/;
        $cpu_idle = $cpu_idle.$1."/";
        $cpu_idle_single = $cpu_idle_single + $1;
        my $l = sprintf "%.1f",(100 - $1);
        $cpu_load = $cpu_load.$l."/";  

        $out = $_;
        if ($out =~ /Cpu.*/) {
            $cpu_count++
        };

    }

    close(SHELL);

    $cpu_load =~ s/\/$//;
    $cpu_user =~ s/\/$//;
    $cpu_system =~ s/\/$//;
    $cpu_nice =~ s/\/$//;
    $cpu_idle =~ s/\/$//;

    $cpu_user_single = $cpu_user_single/$cpu_count;
    $cpu_system_single = $cpu_system_single/$cpu_count;
    $cpu_nice_single = $cpu_nice_single/$cpu_count;
    $cpu_idle_single = $cpu_idle_single/$cpu_count;

    $cpu_user_single = sprintf "%.1f",$cpu_user_single;
    $cpu_system_single = sprintf "%.1f",$cpu_system_single;
    $cpu_nice_single = sprintf "%.1f",$cpu_nice_single;
    $cpu_idle_single = sprintf "%.1f",$cpu_idle_single;

    if ($debug2) {
        print "CPU count       : $cpu_count\n";
        print "CPU load        : $cpu_load\n";
        print "CPU user load   : $cpu_user\n";
        print "CPU sys. load   : $cpu_system\n";
        print "CPU nice load   : $cpu_nice\n";
        print "CPU idle        : $cpu_idle\n";
        print "CPU user single : $cpu_user_single\n";
        print "CPU sys. single : $cpu_system_single\n";
        print "CPU nice single : $cpu_nice_single\n";
        print "CPU idle single : $cpu_idle_single\n";
    }

    return $cpu_load,$cpu_user,$cpu_system,$cpu_nice,$cpu_idle,$cpu_user_single,$cpu_system_single,$cpu_nice_single,$cpu_idle_single;
}

sub get_uptime {
    my ($shell_exec) = @_;
    my $command = $shell_exec." uptime 2>/dev/null; |";

    my $uptime = open(SHELL, $command);
    while (<SHELL>) {
        $_ =~ m/up(.*),\s*load/;
        $uptime = $1;
    }
    close(SHELL);

    print ("Uptime is: $uptime\n") if ($debug2);
    return $uptime;
}

sub fix {
    my ($s) = @_;
    if ($s < 10) { $s = "0".$s; }
    return $s;
}

sub show_processes_stats {
    my ($title,$process_list,$shell_exec) = @_;
    my $command = "";
    my $load = "-1";
    my $rss = "-1";
    my @proc_list = split(/,/, $process_list);
    for (@proc_list) {
        my $process = $_;

        $command = $shell_exec." top -b -n1 2>/dev/null | grep $process | awk '{ totuse = totuse + \$9 } END { print totuse }' 2>/dev/null; |";
        print ("get_load_cmd:".$command."\n") if ($debug2);
        $load = open(SHELL, $command);
        while (<SHELL>) {
            $_ =~ m/([0-9]+)/;
            $load=$1;
        }
        close(SHELL);
        print ("$process load is: $load\n") if ($debug2);

        $command = $shell_exec." /bin/ps --no-headers -o pmem,rss -C $process 2>/dev/null; |";
        print ("get_rss_cmd:".$command."\n") if ($debug2);
        $rss = open(SHELL, $command);
        while (<SHELL>) {
            #$_ =~ m/([0-9]+)/;
            $rss=$_;
        }
        close(SHELL);
        print ("$process RSS is: $rss") if ($debug2);

        $rss =~ m/\s*([0-9\.]*)\s*([0-9]*)/;
        my $rss_percent = $1;
        my $rss_kib =$2;
        $rss_kib = $rss_kib/1024;
        $rss_kib = sprintf "%.0f",$rss_kib;

        if ($debug) {
            print "Process: ".$process."\n";
            print "    CPU Load(%): ".$load."\n";
            print "    RSS(MBytes): ".$rss_kib."\n";
            print "    RSS(%)     : ".$rss_percent."\n";
        }

        &stack_notify(
#        title
#        origin
#        description
#        extra
#        image
#        progress_text
#        progress
#        timeout
#        style
#        ip_list
        $process,
        ,"",
        $cpu_load_str.$load."%",
        $memory_usage_str.$rss_kib." MBytes / ".$rss_percent."%",
        $osd_memory_icon,
        "",
        $rss_percent/100,
        $osd_temps_timeout,
        $temps_style,
        $fe_ip_list
        )

    }
}






given ($action) {


    when ($action eq "server_status") {
        $shell_cmd = $remote_shell_cmd;
        $proces_list = $backend_proces_list;
        $title = $server_title_str;
        goto show_status;
    }


    when ($action eq "frontend_status") {
        $shell_cmd = "";
        $proces_list = $frontend_proces_list;
        $title = $frontend_title_str;

    show_status:
        my $gpu_t = &get_gpu_temp($shell_cmd);
        my ($cpu_fam,$cpu_mod,$cpu_nam,$cpu_freq) = &get_cpu_info($shell_cmd);
        my ($cpu_t,$sys_t,$cpu_f,$sys_f) = &get_cpu_sys_temp_fans($shell_cmd);
        my ($cpu_load,$cpu_system,$cpu_user,$cpu_nice,$cpu_idle,$cpu_system_single,$cpu_user_single,$cpu_nice_single,$cpu_idle_single) = &get_cpu_load($shell_cmd);

        my $temps = "Temps: CPU=";
        $temps = $temps.$cpu_t."C";
        if ( $gpu_t != -1 && $gpu_t != 0 ) {
            $temps = $temps.", GPU=".$gpu_t."C";
        }
        if ( $sys_t != -1 && $sys_t != 0 ) {
            $temps = $temps.", Sys=".$sys_t."C";
        }

        my $fans = "";
        if ( $cpu_f != -1 && $cpu_f != 0 ) {
            $fans = $fans." | Fans: CPU=".$cpu_f."rpm";
        }
        if ( $sys_f != -1 && $sys_f != 0 ) {
            $fans = $fans.", Sys=".$sys_f."rpm";
        }

        my ($uptime) = &get_uptime($shell_cmd);

        if ($debug) {
            print "System Uptime:".$uptime."\n";
            print "Temperatures:"."\n";
            print "    CPU: ".$cpu_t."\n";
            print "    GPU: ".$gpu_t."\n";
            print "String: ".$temps."\n";

        }

        my $idle = 1 - $cpu_idle_single/100;

        &stack_notify(
#        title
#        origin
#        description
#        extra
#        image
#        progress_text
#        progress
#        timeout
#        style
#        ip_list
        $title.$hardware_str,
        $uptime_str.$uptime,
        $temps.$fans,
        $cpu_freq_str.$cpu_freq,
        $osd_temperatures_icon,
        $cpu_load_str.$cpu_load,
        $idle,
        $osd_temps_timeout,
        $temps_style,
        $fe_ip_list
        )

        &show_processes_stats($title,$proces_list,$shell_cmd);

        &sent_notifies_to_all_hosts

    }


    when ($action eq "next_recordings") {

        my $e;
        my $msg ="";

        my $fe_status = load_xml();

        my $data = XMLin($fe_status, KeyAttr=>'encoder');


        foreach $e (@{$data->{Scheduled}->{Program}}) {
            my $normalized_start_time = DateTime::Format::ISO8601->parse_datetime( $e->{startTime} );
            my $strt_time = $normalized_start_time->clone->set_time_zone( 'local' );
            $strt_time =~ s/.*T//g;
            $strt_time =~ s/:..$//g;
            my $normalized_end_time = DateTime::Format::ISO8601->parse_datetime( $e->{endTime} );
            my $end_time = $normalized_end_time->clone->set_time_zone( 'local' );
            $end_time =~ s/.*T//g;
            $end_time =~ s/:..$//g;
            my $recorder = fix($e->{Recording}->{encoderId});
            my $channel = $e->{Channel}->{callSign}; 
            my $title = $e->{title}; 
            #$title = $title.(substr $title, 0, 110);

            stack_notify(
                # title
                # origin
                # description
                # extra
                # image
                # progress_text
                # progress
                # timeout
                # style
                # ip_list
                $channel,
                $title,
                $starts_str.$strt_time.$ends_str.$end_time.$recorder_id_str.$recorder,
                "",
                $osd_nextrec_icon,
                "",
                "",
                $osd_nextrec_timeout,
                $nextrec_style,
                $fe_ip_list
            )

        }

        &sent_notifies_to_all_hosts

    }



    when ($action eq "next_recordings_big") {

        my $e;
        my $msg ="";

        my $fe_status = load_xml();

        my $data = XMLin($fe_status, KeyAttr=>'encoder');


        foreach $e (@{$data->{Scheduled}->{Program}}) {
            my $normalized_start_time = DateTime::Format::ISO8601->parse_datetime( $e->{startTime} );
            my $strt_time = $normalized_start_time->clone->set_time_zone( 'local' );
            $strt_time =~ s/.*T//g;
            $strt_time =~ s/:..$//g;
            my $recording = "".$strt_time." | ";
            $recording = $recording."Rec:".fix($e->{Recording}->{encoderId})." | ";
            $recording = $recording."".$e->{Channel}->{callSign}." | "; 
            $recording = $recording."".$e->{title}.""; 
            $msg = $msg.(substr $recording, 0, 80)."\n";
        }

        if ($msg eq "") {$msg = "None"};

        if ($debug) { print "Next recordings:\n"; }

        stack_notify(
#        title
#        origin
#        description
#        extra
#        image
#        progress_text
#        progress
#        timeout
#        style
#        ip_list
        $next_recordings_str,
        $msg,
        "",
        "",
        $osd_nextrec_icon,
        "",
        "",
        $osd_nextrec_timeout,
        $nextrec_style_big,
        $fe_ip_list
        )

        &sent_notifies_to_all_hosts

    }



    when ($action eq "--help") {
        print "\nAvaliable params. are:\n\t\"frontend_status\"\n\t\"tuners_status\"\n\t\"next_recordings\"\n\t\"next_recordings_big\"\n\n";
    }



    default {
        my $e;
        my $idle;

        my $fe_status = load_xml();

        my $data = XMLin($fe_status, KeyAttr=>'encoder');

        foreach $e (@{$data->{Encoders}->{Encoder}}) {
            $e->{devlabel} =~ s/[\s,\]\[]//g;

            my $tunerName = $e->{devlabel};

            my $tunerStatus = "Unknown";
            if ($e->{state} eq "1") { $tunerStatus="LiveTV"}
            if ($e->{state} eq "7") { $tunerStatus="Recording"}

            if (($e->{state} eq "1") || ($e->{state} eq "7")) {
                my $channelNum = $e->{Program}->{Channel}->{chanNum};
                my $channelName = $e->{Program}->{Channel}->{callSign};
                my $progTitle = $e->{Program}->{title};
                my $startTime = DateTime::Format::ISO8601->parse_datetime($e->{Program}->{startTime}) or die;
                my $endTime = DateTime::Format::ISO8601->parse_datetime($e->{Program}->{endTime}) or die;
                my $currentTime = DateTime->now(time_zone=>'UTC') or die;
                my $durationTime = $endTime - $startTime;
                my $tillendTime = $endTime - $currentTime;
                my $frombegTime = $currentTime - $startTime;
                my $duration = fix($durationTime->hours).":".fix($durationTime->minutes).":".fix($durationTime->seconds);
                my $recorded = fix($frombegTime->hours).":".fix($frombegTime->minutes).":".fix($frombegTime->seconds);
                my $tillend = fix($tillendTime->hours).":".fix($tillendTime->minutes).":".fix($tillendTime->seconds);
                my $dur_sec = ($durationTime->hours)*3600 + ($durationTime->minutes)*60 + $durationTime->seconds;
                my $progress_sec = ($frombegTime->hours)*3600 + ($frombegTime->minutes)*60 + $frombegTime->seconds;
                my $progress = $progress_sec/$dur_sec;

                if ($progress > 1) { $progress=1 };

                if ($endTime < $currentTime ) { $duration = ": Recording is finished." };

                if ($debug) {
                    print "Tuner : ",$tunerName,"\n";
                    print "Status: ".$tunerStatus."\n";
                    print "    Channel.num : ",$channelNum,"\n";
                    print "    Channel.name: ",$channelName,"\n";
                    print "    Title       : ",$progTitle,"\n";
                    print "    Duration    : ",$duration,"\n";
                    print "    Recorded    : ",$recorded,"\n";
                    print "    Till End    : ",$tillend,"\n";
                    print "    Dur(sec)    : ",$dur_sec,"\n";
                    print "    Rec(sec)    : ",$progress_sec,"\n";
                    print "    Rec(%)      : ",$progress*100,"%\n";
                }

                if ($e->{state} eq "1") {
                    $idle = 1;
                    &stack_notify(
                    $channelName,
                    "",
                    $progTitle."    [".$tunerName."]",
                    "",
                    $osd_livetv_icon,
                    "",
                    $progress,
                    $osd_recorders_timeout,
                    $recorders_style,
                    $fe_ip_list
                    )
                }

                if ($e->{state} eq "7") {
                    $idle = 1;
                    &stack_notify(
                    $channelName,
                    "",
                    $progTitle."    [".$tunerName."]",
                    "",
                    $osd_recording_icon,
                    "",
                    $progress,
                    $osd_recorders_timeout,
                    $recorders_style,
                    $fe_ip_list
                    )
                }

            }
        }
        if (! $idle) {
                    &stack_notify(
                    $tuners_str,
                    "",
                    $all_tuners_idle_str,
                    "",
                    $osd_livetv_icon,
                    "",
                    "",
                    $osd_recorders_timeout,
                    $recorders_style,
                    $fe_ip_list
                    )
        }

        &sent_notifies_to_all_hosts

    }
}
