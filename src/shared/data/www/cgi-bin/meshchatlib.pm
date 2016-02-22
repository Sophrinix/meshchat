BEGIN { push @INC, '/www/cgi-bin', '/usr/lib/cgi-bin' }

use meshchatconfig;

sub dbg {
    my $txt = shift;

    if ( $debug == 1 ) { print "$txt\n"; }
}

sub get_lock {
    open( $lock_fh, '<' . $lock_file );

    if ( flock( $lock_fh, 2 ) ) {
        return;
    }
    else {
        die('could not get lock');
    }
}

sub node_name {
    if ( $platform eq 'node' ) {
        return lc( nvram_get("node") );
    }
    elsif ( $platform eq 'pi' ) {
        open( HST, "/etc/hostname" );
        my $hostname = <HST>;
        close(HST);

        chomp($hostname);

        if ( $hostname eq '' ) {
            $hostname = `hostname`;
            chomp($hostname);
        }

        return lc($hostname);
    }
}

sub release_lock {
    close($lock_fh);
}

sub file_md5 {
    my $file = shift;

    if (!-e $file) { return ''; }

    my $output = `md5sum $file`;

    # Fix to work on OSX

    if ( $output eq '' ) {
        $output = `md5 -r $file`;
    }

    my @parts = split( /\s/, $output );

    return $parts[0];
}

sub file_size {
    my $file = shift;

    my @stats = stat($file);

    return $stats[7];
}

sub file_epoch {
    my $file = shift;

    my @stats = stat($file);

    return $stats[9];
}

sub get_messages_db_version {
    open( VER, $messages_version_file );
    my $ver = <VER>;
    chomp($ver);
    close(VER);

    return $ver;
}

sub save_messages_db_version {
    open( VER, '>' . $messages_version_file );
    print VER messages_db_version() . "\n";
    close(VER);

    chmod( 0666, $messages_version_file );
}

sub messages_db_version {
    my $sum = 0;

    open( MSG, $messages_db_file );
    while (<MSG>) {
        my $line = $_;
        chomp($line);

        my @parts = split( "\t", $line );

        if ( $parts[0] =~ /[0-9a-f]/ ) {
            $sum += hex( $parts[0] );
        }
    }
    close(MSG);

    return $sum;
}

sub file_storage_stats {

    #my $stats = `df | grep /tmp | awk '{print $2} {print $3}'`;
    my @lines = `df -k $local_files_dir`;

    my ( $dev, $blocks, $used, $available ) = split( /\s+/, $lines[1] );

    $used      = $used * 1024;
    $available = $available * 1024;

    $total = $used + $available;

    my $local_files_bytes = 0;

    if ( $platform eq 'pi' ) {
        $max_file_storage  = $total * 0.95;
        $local_files_bytes = $used;
    }

    if ( $platform eq 'node' ) {
        get_lock();

        opendir( my $dh, $local_files_dir );
        my $file;

        while ( $file = readdir($dh) ) {
            if ( $file !~ /^\./ ) {
                $local_files_bytes += file_size( $local_files_dir . '/' . $file ),;
            }
        }
        closedir($dh);

        release_lock();
    }

    if (($max_file_storage - $local_files_bytes) < 0) {
        $local_files_bytes = $max_file_storage;
    }

    return {
        total      => $total,
        used       => $used,
        files      => $local_files_bytes,
        files_free => $max_file_storage - $local_files_bytes,
        allowed    => $max_file_storage
    };
}

sub node_list {
    my $nodes;

    if ( $platform eq 'node' ) {
        $nodes = mesh_node_list();
    }
    else {
        $nodes = pi_node_list();
    }

    push( @$nodes, @$extra_nodes );    

    foreach my $node (@$nodes) {
        dbg "$$node{platform} $$node{node} $$node{port}\n";
    }

    dbg "\n\n";

    return $nodes;
}

sub pi_node_list {
    dbg "pi_node_list";    

    my $local_node = node_name();

    my @output = `curl --retry 0 --connect-timeout $connect_timeout http://localnode.local.mesh:8080/cgi-bin/meshchat\\?action=meshchat_nodes 2> /dev/null`;

    my $nodes = [];

    foreach my $line (@output) {
        my ($node, $port) = split("\t", $line);

        if (lc($local_node) eq lc($node)) { next; }

        if ($port == 8080) {
            push( @$nodes, { platform => 'node', node => $node } );
        } else {
            push( @$nodes, { platform => 'pi', node => $node } );
        }
    }

    return $nodes;
}

sub mesh_node_list {
    dbg "mesh_node_list";

    my $local_node = node_name();

    foreach (`grep -i "/meshchat|" /var/run/services_olsr`) {
        chomp;
        if ($_ =~ /^http:\/\/(.*)\:(\d+)\//) {
            if (lc($local_node) eq lc($1)) { next; }

            if ($2 == 8080) {
                push( @$nodes, { platform => 'node', node => lc($1), port => $2 } );
            } else {
                push( @$nodes, { platform => 'pi', node => lc($1), port => $2 } );
            }
        }
    }

    return $nodes;
}

sub uri_unescape {

    # Note from RFC1630:  "Sequences which start with a percent sign
    # but are not followed by two hexadecimal characters are reserved
    # for future extension"
    my $str = shift;
    if ( @_ && wantarray ) {

        # not executed for the common case of a single argument
        my @str = ( $str, @_ );    # need to copy
        for (@str) {
            s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        }
        return @str;
    }
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $str;
    $str;
}

sub url_escape {
    my ($rv) = @_;
    $rv =~ s/([^A-Za-z0-9])/sprintf("%%%2.2X", ord($1))/ge;
    return $rv;
}

#### perlfunc.pm

sub nvram_get {
    my ($var) = @_;
    return "ERROR" if not defined $var;
    chomp( $var = `uci -c /etc/local/uci/ -q get hsmmmesh.settings.$var` );
    return $var;
}

$stdinbuffer = "";

sub fgets {
    my ($size) = @_;
    my $line = "";
    while (1) {
        unless ( length $stdinbuffer ) {
            return "" unless read STDIN, $stdinbuffer, $size;
        }
        my ( $first, $cr ) = $stdinbuffer =~ /^([^\n]*)(\n)?/;
        $cr = "" unless $cr;
        $line .= $first . $cr;
        $stdinbuffer = substr $stdinbuffer, length "$first$cr";
        if ( $cr or length $line >= $size ) {
            if (0) {
                $line2 = $line;
                $line2 =~ s/\r/\\r/;
                $line2 =~ s/\n/\\n/;
                push @parse_errors, "[$line2]";
            }
            return $line;
        }
    }
}

# read postdata
# (from STDIN in method=post form)
sub read_postdata {
    print STDERR "read_postdata\n$ENV{REQUEST_METHOD}\n$ENV{REQUEST_METHOD}";
    if ( $ENV{REQUEST_METHOD} != "POST" || !$ENV{REQUEST_METHOD} ) { return; }
    my ( $line, $parm, $file, $handle, $tmp );
    my $state = "boundary";
    my ($boundary) = $ENV{CONTENT_TYPE} =~ /boundary=(\S+)/ if $ENV{CONTENT_TYPE};
    my $parsedebug = 0;
    push( @parse_errors, "[$boundary]" ) if $parsedebug;
    while ( length( $line = fgets(1000) ) ) {
        $line =~ s/[\r\n]+$//;    # chomp doesn't strip \r!
        print STDERR "[$state] $line<br>\n";

        if ( $state eq "boundary" and $line =~ /^--$boundary(--)?$/ ) {
            last if $line eq "--$boundary--";
            $state = "cdisp";
        }
        elsif ( $state eq "cdisp" ) {
            my $prefix = "Content-Disposition: form-data;";
            if ( ( $parm, $file ) = $line =~ /^$prefix name="(\w+)"; filename="(.*)"$/ ) {    # file upload
                $parms{$parm} = $file;
                if   ($file) { $state = "ctype" }
                else         { $state = "boundary" }
            }
            elsif ( ($parm) = $line =~ /^$prefix name="(\w+)"$/ ) {                           # form parameter
                $line = fgets(10);
                push( @parse_errors, "not blank: '$line'" ) unless $line eq "\r\n";
                $line = fgets(1000);
                $line =~ s/[\r\n]+$//;
                $parms{$parm} = $line;
                $state = "boundary";
            }
            else {                                                                            # oops, don't know what this is
                push @parse_errors, "unknown line: '$line'";
            }
        }
        elsif ( $state eq "ctype" )                                                           # file upload happens here
        {
            push( @parse_errors, "unexpected: '$line'" ) unless $line =~ /^Content-Type: /;
            $line = fgets(10);
            push( @parse_errors, "not blank: '$line'" ) unless $line eq "\r\n";
            $tmp = "";
            system "mkdir -p $tmp_upload_dir";
            open( $handle, ">$tmp_upload_dir/file" );
            while (1) {

                # get the next line from the form
                $line = fgets(1000);
                last unless length $line;
                last if $line =~ /^--$boundary(--)?\r\n$/;

                # make sure the trailing \r\n doesn't get into the file
                print $handle $tmp;
                $tmp = "";
                if ( $line =~ /\r\n$/ ) {
                    $line =~ s/\r\n$//;
                    $tmp = "\r\n";
                }
                print $handle $line;
            }
            close($handle);
            last if $line eq "--$boundary--\r\n";
            $state = "cdisp";
        }
    }

    push( @parse_errors, `md5sum $tmp_upload_dir/file` ) if $parsedebug and $handle;
}

1;
