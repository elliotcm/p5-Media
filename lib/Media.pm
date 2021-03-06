package Media;

use Modern::Perl;
use MooseX::FollowPBP;
use Moose;
use MooseX::Method::Signatures;

use Config::Std;
use File::Copy;
use File::Path;
use FileHandle;
use IO::All;
use IO::CaptureOutput   qw( capture_exec );
use IPC::DirQueue;
use Media::Handler::DVD;
use Media::Handler::Movie;
use Media::Handler::TV;
use Media::Handler::VHS;
use Readonly;
use Storable        qw( freeze thaw store retrieve );
use Time::Elapsed   qw( elapsed );
use TryCatch;
use version;

our $VERSION                     = qv( 0.9.4 );
use constant RESERVED_PRIORITY   => 1;
use constant HIGHEST_PRIORITY    => 2;
use constant LOWEST_PRIORITY     => 100;
use constant MEDIA_TYPES         => qw( DVD Movie TV VHS );
use constant QUEUE_POLL_TIMEOUT  => 0;
use constant QUEUE_POLL_INTERVAL => 15;
Readonly my $CONVERSION_FILE     => 'Z-conversion.m4v';
Readonly my $CONVERTED_FILE      => 'Z-converted.m4v';

with 'Media::Config';

has log_file => (
        isa     => 'Str',
        is      => 'rw',
        default => 'media.log',
    );
has log_file_handle => ( 
        isa => 'FileHandle', 
        is  => 'rw',
    );
has handlers => (
        isa => 'HashRef',
        is  => 'rw',
    );
has config_file => (
        isa     => 'Str',
        is      => 'ro',
        default => $ENV{'MEDIA_CONFIG'} 
                // "$ENV{'HOME'}/etc/media.conf",
    );
has configuration => (
        isa => 'Config::Std::Hash',
        is  => 'rw',
    );
has ignoring => (
        isa => 'HashRef',
        is  => 'rw',
    );

method BUILD {
    my %config = $self->get_default_config();
    
    try {
        read_config $self->get_config_file(), %config;
    }
    
    $self->set_configuration( \%config );
    $self->open_log_file();
    
    $self->load_ignoring();
    
    my %handlers;
    foreach my $type ( MEDIA_TYPES ) {
        my $class = "Media::Handler::${type}";
        $handlers{ $type } = $class->new(
                log_file_handle => $self->get_log_file_handle(),
                media           => $self,
            );
    }
    $self->set_handlers( \%handlers );
}



method process_directory ( Str $directory, Int $priority = 50 ) {
    my $handler = $self->get_handler( $directory );
    
    if ( defined $handler ) {
        $handler->install_from( $directory, $priority );
    }
    else {
        # if not an obvious candidate, now look for an import file
        if ( -f "${directory}/import" ) {
            $self->import_from( $directory, $priority );
        }
        # otherwise, just recurse down any possible subdirectories
        else {
            opendir( my $handle, $directory );
            while ( my $entry = readdir $handle ) {
                next if $entry =~ m{^\.};
                
                my $target = "$directory/$entry";
                if ( -d $target ) {
                    $self->process_directory( $target, $priority );
                }
            }
            closedir $handle;
        }
    }
}
method process_result (
    Str $condition, 
    Str $archive,
    Str $directory,
    Str $elapsed_time = 0,
    Str $par_message = ''
) {
    # if the new directory is in the base, trim the full pathname 
    # (I find this makes the logs much easier to read quickly)
    my $base = $self->get_config( 'base_directory' );
    chdir $base;
    $directory =~ s{^$base/}{};
    
    if ( 'ERROR' eq $condition ) {
        $self->write_log( "ERROR with $directory: $par_message" );
    }
    else {
        $self->process_directory( $directory, 25 );
    }
}

method get_handler ( Str $name ) {
    my $type = $self->determine_type( $name );
    
    return $self->get_handler_type( $type )
        if defined $type;
    return;
}
method determine_type ( Str $name ) {
    my ( $type, undef ) = $self->parse_type_for_hint( $name );
    
    if ( !defined $type ) {
        my $handlers = $self->get_handlers();
        my %types;
        
        foreach my $try ( keys %{ $handlers } ) {
            my $handler = $handlers->{ $try };
            my ( $type, $confidence ) = $handler->is_type( $name );
            
            $types{ $type } = ( $confidence // 0 )
                if defined $type;
        }
        
        my $confidence = 0;
        foreach my $instance ( keys %types ) {
            if ( $confidence < $types{ $instance } ) {
                $type       = $instance;
                $confidence = $types{ $instance };
            }
        }
    }
    
    return $type;
}
method get_handler_type ( Str $type ) {
    my $handlers = $self->get_handlers();
    
    return $handlers->{ $type };
}
method parse_type_for_hint ( Str $type ) {
    my $directory = $self->strip_leading_directories( $type );

    # hinted types look like "VHS -- Midnight Caller - 1x01 - Pilot"
    if ( $directory =~ m{^ ( [A-Z]+ ) \s+ -- \s+ (.*) $}x ) {
        return( $1, $2 );
    }
    return( undef, $type );
}
method strip_leading_directories ( Str $path ) {
    # only attempt this on actual filenames that
    # contain more than one path element
    if ( index( $path, '/' ) > -1 ) {
        # strip trailing slashes
        $path =~ s{/$}{};
        
        # strip leading path elements
        $path =~ s{^ .*/ }{}x;
    }
    
    return $path;
}

method queue_stop_job {
    my $queue   = $self->get_conversion_queue();
    my $payload = freeze( { end_queue => 1, } );
    
    $queue->enqueue_string( $payload, undef, RESERVED_PRIORITY );
}
method queue_conversion ( HashRef $options, Int $priority = 50 ) {
    my $queue   = $self->get_conversion_queue();
    my $payload = freeze( $options );
    
    $priority = HIGHEST_PRIORITY
        if $priority < HIGHEST_PRIORITY;
    $priority = LOWEST_PRIORITY
        if $priority > LOWEST_PRIORITY;
    
    $queue->enqueue_string( $payload, undef, $priority );
}
method dequeue_conversion ( Int $now = 0 ) {
    my $queue    = $self->get_conversion_queue();
    my $timeout  = $now ? 1 : QUEUE_POLL_TIMEOUT;
    my $interval = $now ? 1 : QUEUE_POLL_INTERVAL;
    
    my $job = $queue->wait_for_queued_job( 
                  $timeout, 
                  $interval 
              );
    
    if ( defined $job ) {
        my $payload = $job->get_data();
        return( $job, thaw( $payload ) );
    }
    
    return;
}
method get_conversion_queue {
    my $data_dir  = $self->get_config( 'data_directory' );
    my $directory = "${data_dir}/conversion";
    
    return IPC::DirQueue->new( { dir => $directory } );
}
method list_all_in_queue {
    my $queue = $self->get_conversion_queue();
    my @jobs;
    
    my $visitor = sub {
            my $context = shift;
            my $job     = shift;
            my $payload = $job->get_data();
            my $id      = $job->{'jobid'};
            
            push @jobs, {
                    active   => $job->{'active_pid'},
                    priority => substr( $id, 0, 2 ),
                    payload  => thaw( $payload ),
                    path     => $job->{'pathqueue'},
                };
        };
    
    $queue->visit_all_jobs( $visitor );
    
    return @jobs;
}
method remove_queued_job ( Str $path ) {
    my $queue = $self->get_conversion_queue();
    my $job   = $queue->pickup_queued_job( path => $path );
    
    if ( defined $job ) {
        my $data     = $job->get_data();
        my $payload  = thaw( $data );
        my $input    = $payload->{'input'};
        my $title    = $payload->{'options'}{'-t'};
        my $stop_job = $payload->{'end_queue'};
        
        $input = "$input title $title"
            if defined $title;
        $input = "STOP JOB"
            if defined $stop_job;
        
        $job->finish();
        $self->write_log( "REMOVE $input" );
    }
}
method convert_file ( HashRef $job_data ) {
    my $input  = $job_data->{'input'} // '';
    my $output = $job_data->{'output'};
    my $config = $self->get_configuration();
    my( $directory, $filename, $type ) = $self->get_path_segments( $input );
    
    if ( -d "$input/VIDEO_TS" ) {
        $type = 'DVD';
    }
    mkpath( $output );
    
    if ( defined $config->{ $type } ) {
        my $target = "${output}/${CONVERSION_FILE}";
        my $start   = time();
        my $args    = $job_data->{'options'} // {};
        my $message = "Converting $input";
           $message .= ' title ' . $args->{'-t'}
                if defined $args->{'-t'};
        
        $self->write_log( $message );
        
        # original source type can provide extra flags 
        # (enable denoise on VHS sources, for example)
        my $source = $args->{'source_type'} 
                     // 'default_source';
        delete $args->{'source_type'};
        
        # get initial options -- this allows more specific options
        # to override the general settings before it
        my %options = (
                %{ $config->{'common'}  },
                %{ $config->{ $source } },
                %{ $config->{ $type }   },
                %{ $args },
            );
        
        # augment options with the actual audio and subtitle arguments, 
        # not just the cryptic string detailing which formats to use
        %options = (
                %options,
                $self->get_audio_args( $job_data, $type ),
                $self->get_subtitle_args( $job_data ),
            );
        delete $options{'audio'};
        delete $options{'subtitle'};
        
        # try and find a poster image, either from the options
        # hash, or the input processing directory (which
        # overrides the options if both exist)
        if ( defined $options{'poster'} ) {
            $self->get_poster( $output, $options{'poster'} );
        }
        delete $options{'poster'};
        
        my $saved_poster = "${directory}/poster.jpg";
        if ( -f $saved_poster ) {
            copy( $saved_poster, $output );
        }
        
        # turn arguments like "quality" into "--quality" (this 
        # makes the configuration file more readable), also notes
        # "no-loose-anamorphic" style arguments and then removes them
        my %encoding_arguments;
        my @remove_arguments;
        foreach my $key ( keys %options ) {
            my $value = $options{ $key };
            
            if ( $key =~ m{^no-(.*)} ) {
                push @remove_arguments, $1;
            }
            else {
                $key = "--$key" unless '-' eq substr( $key, 0, 1 );
                $encoding_arguments{ $key } = $value;
            }
        }
        foreach my $key ( @remove_arguments ) {
            delete $encoding_arguments{"--$key"};
        }
        
        my @handbrake_command_line = (
                'HandBrakeCLI',
                %encoding_arguments,
                '-i',
                $input,
                '-o',
                $target,
            );
        
        say join ' ', @handbrake_command_line;
        system @handbrake_command_line;
        
        my $end     = time();
        my $elapsed = elapsed( $end - $start );
        $self->write_log( "Done - took $elapsed" );
        
        my $converted = "${output}/${CONVERTED_FILE}";
        move( $target, $converted );
        
        $self->trash_file( $input );
    }
    else {
        $self->write_log( "ERROR: no type (${type}) for ${input}")
    }
}
method get_audio_args ( HashRef $job_data, Str $type ) {
    my $config     = $self->get_configuration();
    my $options    = $job_data->{'options'}{'audio'};
    my %audio_args = ( '-a' => [], '-E' => [], '-B' => [], '-A' => [], 
                       '-6' => [], '-R' => [], '-D' => [] );
    my @audio_streams;
    
    if ( defined $options ) {
        if ( 'ARRAY' eq ref $options ) {
           push @audio_streams, @{ $options };
        }
        else {
           push @audio_streams, $options;
        }
    }
    else {
        if ( defined $config->{ $type }{'audio'} ) {
            push @audio_streams, @{ $config->{ $type }{'audio'} };
        }
        else {
            push @audio_streams, @{ $config->{'common'}{'audio'} };
            
        }
    }
    
    foreach my $stream ( @audio_streams ) {
        if ( $stream =~ m{ (\d+) \: (\w+) (?: \: (.*) )? }x ) {
            my $track  = $1;
            my $format = $2;
            my $name   = $3;
            
            push @{ $audio_args{'-a'} }, $track;
            
            if ( 'ac3' eq $format ) {
                push @{ $audio_args{'-E'} }, 'ac3';
                push @{ $audio_args{'-B'} }, '160';
                push @{ $audio_args{'-6'} }, 'auto';
                push @{ $audio_args{'-R'} }, 'Auto';
                push @{ $audio_args{'-D'} }, '0.0';
                push @{ $audio_args{'-A'} }, $name // 'Dolby Surround';
            }
            else {
                my $key = "audio_${format}";
                
                push @{ $audio_args{'-E'} }, 
                    $config->{ $key }{'encoder'} // 'ca_aac';
                push @{ $audio_args{'-B'} }, 
                    $config->{ $key }{'bitrate'} // '160';
                push @{ $audio_args{'-6'} }, 
                    $config->{ $key }{'downmix'} // 'dpl2';
                push @{ $audio_args{'-R'} }, 
                    $config->{ $key }{'sample'}  // '48';
                push @{ $audio_args{'-D'} }, 
                    $config->{ $key }{'range'}   // '0.0';
                push @{ $audio_args{'-A'} }, 
                    $name                        // 'Dolby Surround';
            }
        }
    }
    
    my %args;
    foreach my $arg ( keys %audio_args ) {
        $args{ $arg } = join( ',', @{ $audio_args{ $arg } } );
    }
    
    return %args;
}
method get_subtitle_args ( HashRef $job_data ) {
    my $config        = $self->get_configuration();
    my $input         = $job_data->{'input'};
    my $options       = $job_data->{'options'}{'subtitle'};
    my %subtitle_args = ( '--srt-file' => [], '--srt-lang' => [] );
    my $default       = 0;
    my @subtitle_streams;
    
    if ( 'ARRAY' eq ref $options ) {
        push @subtitle_streams, @{ $options };
    }
    else {
        push @subtitle_streams, $options;
    }
    
    # HACK: So ... my Apple TV refuses to properly let me switch between
    # subtitles that are all marked 'eng' or 'und'. So I forcibly mark things
    # as different languages. The labels are now wrong, but the functionality
    # is at least there (and the file can always be edited later by a tool
    # such as Subler, once the ATV does something approaching "right").
    my @lang_codes      = qw( . eng fra spa ger ita );
    my $count           = 1;
    my $subtitle_regexp = qr{
            ( default \: )?     # optional 'default:'
            ( .* )              # filename
        }x;
    
    foreach my $stream ( @subtitle_streams ) {
        last unless defined $stream;
        
        if ( $stream =~ $subtitle_regexp ) {
            my $flagged  = $1;
            my $sub_file = $2;
            
            if ( $flagged ) {
                $default = $count;
            }
            
            if ( -d "$input/VIDEO_TS" ) {
                $sub_file = "${input}/${sub_file}";
            }
            
            push @{ $subtitle_args{'--srt-file'} }, $sub_file;
            push @{ $subtitle_args{'--srt-lang'} }, $lang_codes[ $count ];
            $count++;
        }
    }
    
    # don't return empty "--srt-file ''" args if no subtitles specified
    return 
        if 1 == $count;
    
    my %args;
    foreach my $arg ( keys %subtitle_args ) {
        $args{ $arg } = join( ',', @{ $subtitle_args{ $arg } } );
    }
    
    if ( $default ) {
        $args{'--srt-default'} = $default;
        $args{'--srt-codeset'} = 'UTF-8';
    }
    
    return %args;
}
method get_poster ( Str $destination, Str $poster ) {
    my $target = "$destination/poster.jpg";
    
    if ( $poster =~ m{^http} ) {
        my $ua       = LWP::UserAgent->new();
        my $response = $ua->get( $poster );
        
        if ( $response->is_success ) {
            $response->decoded_content() > io( $target );
        }
        else {
            my $error = $response->status_line;
            $self->write_log( "ERROR fetching cover: $error" );
        }
    }
    else {
        copy( $poster, $target );
    }
}
method open_log_file {
    my $filename       = $self->get_log_file();
    my $base_directory = $self->get_config( 'log_directory' );
    my $log_file       = "${base_directory}/${filename}";
    my $handle         = FileHandle->new( $log_file, 'a' );
    
    die "$log_file: $!" unless defined $handle;
    
    $handle->autoflush( 1 );
    $self->set_log_file_handle( $handle );
}
method write_log ( Str $log_message ) {
    my $handle = $self->get_log_file_handle();
    
    my @time  = localtime( time() );
    my $stamp = sprintf '%02d/%02d %02d:%02d',
                     $time[4]+1,
                     @time[3,2,1];
    
    say "-> $log_message";
    say { $handle } "$stamp $log_message";
}

method tag_file ( Str $file, ArrayRef $arguments ) {
    # I use a binary named 'atomic-parsley' (which is taken from the
    # MetaX.app) to differentiate it from the standard AtomicParsley 
    my( $out, $err ) = capture_exec( 
            'atomic-parsley',
            $file,
            '--overWrite',
            @{ $arguments },
        );
    
    if ( $err !~ m{^ \s* $}sx ) {
        $self->write_log( $err );
    }
    
    # remove the poster image
    my( $directory, undef, undef ) = $self->get_path_segments( $file );
    unlink "$directory/poster.jpg";
}

method get_ignoring_filename {
    my $directory = $self->get_config( 'data_directory' );
    return "${directory}/ignoring.db";
}
method load_ignoring {
    my $filename = $self->get_ignoring_filename();
    
    if ( -f $filename ) {
        $self->set_ignoring( retrieve( $filename ) );
    }
}
method save_ignoring {
    my $filename = $self->get_ignoring_filename();
    my $data     = $self->get_ignoring();
    
    store( $data, $filename )
        or die "ARGH";
}
method is_ignoring ( Str $title ) {
    my $data = $self->get_ignoring();
    
    return defined $data->{ $title };
}
method start_ignoring ( Str $title ) {
    my $data = $self->get_ignoring();
    
    $data->{ $title } = 1;
    $self->set_ignoring( $data );
    $self->save_ignoring();
    
    $self->write_log( "Ignoring $title" );
}

method get_file_extension ( Str $filename ) {
    my( undef, undef, $extension ) = $self->get_path_segments( $filename );
    
    return $extension;
}
method get_path_segments ( Str $filename ) {
    $filename =~ m{
            ^ 
            ( .*/ )?            # optional dirname
            ( [^/]+? )          # file
            ( \. [^\./]+ )?     # optional extension
            $
        }x;
    
    return( $1, $2, $3 );
}
method trash_file ( Str $target ) {
    my $trash_files     = $self->get_config( 'trash_files' );
    my $trash_directory = $self->get_config( 'trash_directory' );
    
    if ( defined $trash_files && $trash_files ) {
        if ( -f $target ) {
            my( undef, $filename, $extension ) 
                = $self->get_path_segments( $target );
            
            my $destination_filename = "${filename}${extension}";

            $self->safely_move_file( 
                    $target, 
                    $trash_directory,
                    $destination_filename,
                    1
                );
        }
    }
}
method safely_move_file (
    Str $from, 
    Str $directory, 
    Str $filename, 
    Int $silent = 0 
) {
    my $extension   = $self->get_file_extension( $filename );
    my $destination = "${directory}/${filename}";
    
    # never overwrite an existing file
    my $count = 2;
    while ( -f $destination ) {
        my $fix_filename = $filename;
           $fix_filename =~ s{ ${extension} $}{ (v${count})${extension}}x;
        
        $destination 
            = "${directory}/${fix_filename}";
        $count++;
    }
    
    $self->write_log( "install ${from}: ${destination}" ) unless $silent;
    mkpath( $directory );
    move( $from, $destination )
        or $self->write_log( "ERROR: move ${from} to ${destination}: $!" );
    
    return $destination;
}
method get_config ( Str $key, Str $block = '' ) {
    my $config = $self->get_configuration();
    
    return $config->{ $block }{ $key };
}

1;

__END__

=head1 NAME

B<Media> -- code and scripts for handling electronic media

=head1 DESCRIPTION

The C<Media> project is a workflow for transforming your existing digital
media into new formats. Commonly, piles of DVDs into much smaller MPEG-4
video files suitable for watching on an Apple TV and/or iPad.

B<Note: Unless you are interested in writing scripts using the C<Media> code,
you should be reading L<Media::Tutorial>, not this.>

=head1 USAGE

... TODO ...
