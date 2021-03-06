##! Find top metrics 

# Contributed by Reservoir Labs, Inc.
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

##!
##! top-metrics.bro is a script that tracks various top metrics in real-time. 
##! The current set of supported top metrics are:
##!
##!   - Top talkers: connections that carry the largest amount of data
##!   - Top URLs: URLs that are hit the most
##!
##! This script reports the following logs:
##!   - topmetrics_talkers.log: for top talkers measurements
##!   - topmetrics_urls.log: for top URLs measurements
##!

@load base/frameworks/sumstats
@load base/protocols/http

module TopMetrics;

export {
    
    ## The duration of the epoch, which defines the time between two consecutive reports
    const epoch_duration: interval = 30 sec &redef;
    ## The size of the top set to track
    const top_size: count = 20 &redef;
    ## The bin size in bytes defining the resolution of the top talkers
    const talker_bin_size = 1000;

    # Logging info
    redef enum Log::ID += { URLS };
    redef enum Log::ID += { TALKERS };

    type Info: record {
        epoch_time: time &log;              ##< Time at the end of the epoch 
        top_list: vector of string &log;    ##< Ordered list of top URLs 
        top_counts: vector of string &log;  ##< Counters for each URL
    };

    # Logging event for tracking the top URLs 
    global log_top_urls: event(rec: Info);
    # Logging event for tracking the top talkers 
    global log_top_talkers: event(rec: Info);

}

event bro_init()
    {
    local rec: TopMetrics::Info;
    Log::create_stream(TopMetrics::URLS, [$columns=Info, $ev=log_top_urls]);
    Log::create_stream(TopMetrics::TALKERS, [$columns=Info, $ev=log_top_talkers]);

    # Define the reducers
    local r1 = SumStats::Reducer($stream="top.urls", $apply=set(SumStats::TOPK), $topk_size=top_size);
    local r2 = SumStats::Reducer($stream="top.talkers", $apply=set(SumStats::TOPK), $topk_size=top_size);

    # Define the SumStats
    SumStats::create([$name="tracking top URLs",
                      $epoch=epoch_duration,
                      $reducers=set(r1),
                      $epoch_result(ts: time, key: SumStats::Key, result: SumStats::Result) =
                          {
                          local r = result["top.urls"];
                          local s: vector of SumStats::Observation;
                          local top_list = string_vec();
                          local top_counts = index_vec();
                          local i = 0;
                          s = topk_get_top(r$topk, top_size);
                          for ( element in s ) 
                              {
                              top_list[|top_list|] = s[element]$str;
                              top_counts[|top_counts|] = topk_count(r$topk, s[element]);
                              if ( ++i == top_size )
                                  break;
                              }
                          Log::write(TopMetrics::URLS, [$epoch_time=ts, 
                                                        $top_list=top_list, 
                                                        $top_counts=top_counts]);
                          }]);
    SumStats::create([$name="tracking top talkers",
                      $epoch=epoch_duration,
                      $reducers=set(r2),
                      $epoch_result(ts: time, key: SumStats::Key, result: SumStats::Result) =
                          {
                          local r = result["top.talkers"];
                          local s: vector of SumStats::Observation;
                          local top_list = string_vec();
                          local top_counts = index_vec();
                          local i = 0;
                          s = topk_get_top(r$topk, top_size);
                          for ( element in s ) 
                              {
                              top_list[|top_list|] = s[element]$str;
                              top_counts[|top_counts|] = topk_count(r$topk, s[element]);
                              if ( ++i == top_size )
                                  break;
                              }
                          Log::write(TopMetrics::TALKERS, [$epoch_time=ts, 
                                                           $top_list=top_list, 
                                                           $top_counts=top_counts]);
                          }]);

    }

event DNS::log_dns(rec: DNS::Info)
    {
        # Observation based on DNS queries
        if ( rec?$query )
            SumStats::observe("top.urls", [], [$str=fmt("%s", rec$query)]);
    }

event ssl_extension_server_name(c: connection, is_orig: bool, names: string_vec)
    {
        # Observation based on the Server Name Indication (SNI)
        for ( index in names )
            SumStats::observe("top.urls", [], [$str=fmt("%s", names[index])]);        
    }

function generate_talker_observations(id: conn_id, total_bytes : count, bytes_left : int)
    {
    # Generate as many observations as total number of bytes this connection has
    # divided by the talker bin size. Resolution of this measurement can be increased
    # by reducing the value of talker_bin_size at the expense of more CPU compute.
    SumStats::observe("top.talkers", [], [$str=fmt("[%s : %s : %s : %s](%d)", id$orig_h, id$orig_p, id$resp_h, id$resp_p, total_bytes)]);
    bytes_left = bytes_left - talker_bin_size;
    if(bytes_left <= 0)
        return;
    generate_talker_observations(id, total_bytes, bytes_left);
    } 

event connection_state_remove(c: connection)
    {
        local total_bytes = c$conn$orig_ip_bytes + c$conn$resp_ip_bytes;
        generate_talker_observations(c$id, total_bytes, total_bytes);
    } 

