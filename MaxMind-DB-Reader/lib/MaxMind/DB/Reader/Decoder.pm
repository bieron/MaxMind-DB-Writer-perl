package MaxMind::DB::Reader::Decoder;

use strict;
use warnings;
use namespace::autoclean;
use autodie;

use Carp qw( confess );
use Encode ();
use MaxMind::DB::Reader::Data::Container;
use MaxMind::DB::Reader::Data::EndMarker;
use Math::Int128 qw( uint128 );
use NetAddr::IP::Util qw( bin2bcd );

use Moose;
use MooseX::StrictConstructor;

with 'MaxMind::DB::Role::Debugs', 'MaxMind::DB::Reader::Role::Sysreader';

use constant DEBUG => $ENV{MAXMIND_DB_DECODER_DEBUG};

# This is a constant so that outside of testing any references to it can be
# optimised away by the compiler.
use constant POINTER_TEST_HACK => $ENV{MAXMIND_DB_POINTER_TEST_HACK};

binmode STDERR, ':utf8'
    if DEBUG;

my %Types = (
    0  => 'extended',
    1  => 'pointer',
    2  => 'utf8_string',
    3  => 'double',
    4  => 'bytes',
    5  => 'uint16',
    6  => 'uint32',
    7  => 'map',
    8  => 'int32',
    9  => 'uint64',
    10 => 'uint128',
    11 => 'array',
    12 => 'container',
    13 => 'end_marker',
);

has _pointer_base => (
    is       => 'ro',
    isa      => 'Int',
    init_arg => 'pointer_base',
    default  => 0,
);

sub decode {
    my $self   = shift;
    my $offset = shift;

    confess 'You must provide an offset to decode from when calling ->decode'
        unless defined $offset;

    if (DEBUG) {
        $self->_debug_newline();
        $self->_debug_string( 'Offset', $offset );
    }

    my $ctrl_byte;
    $self->_read( \$ctrl_byte, $offset, 1 );
    $offset++;

    $self->_debug_binary( 'Control byte', $ctrl_byte )
        if DEBUG;

    $ctrl_byte = unpack( C => $ctrl_byte );

    # The type is encoded in the first 3 bits of the byte.
    my $type = $Types{ $ctrl_byte >> 5 };

    $self->_debug_string( 'Type', $type )
        if DEBUG;

    # Pointers are a special case, we don't read the next $size bytes, we use
    # the size to determine the length of the pointer and then follow it.
    if ( $type eq 'pointer' ) {
        my ( $pointer, $new_offset )
            = $self->_decode_pointer( $ctrl_byte, $offset );

        return $pointer if POINTER_TEST_HACK;

        my $value = $self->decode($pointer);
        return wantarray
            ? ( $value, $new_offset )
            : $value;
    }

    if ( $type eq 'extended' ) {
        my $next_byte;
        $self->_read( \$next_byte, $offset, 1 );

        $self->_debug_binary( 'Next byte', $next_byte )
            if DEBUG;

        my $type_num = unpack( C => $next_byte ) + 7;
        confess
            "Something went horribly wrong in the decoder. An extended type resolved to a type number < 8 ($type_num)"
            unless $type_num >= 8;

        $type = $Types{$type_num};
        $offset++;
    }

    ( my $size, $offset )
        = $self->_size_from_ctrl_byte( $ctrl_byte, $offset );

    $self->_debug_string( 'Size', $size )
        if DEBUG;

    # The map and array types are special cases, since we don't read the next
    # $size bytes. For all other types, we do.
    return $self->_decode_map( $size, $offset )
        if $type eq 'map';

    return $self->_decode_array( $size, $offset )
        if $type eq 'array';

    my $buffer;
    $self->_read( \$buffer, $offset, $size )
        if $size;

    $self->_debug_binary( 'Buffer', $buffer )
        if DEBUG;

    my $method = '_decode_' . $type;
    return wantarray
        ? ( $self->$method( $buffer, $size ), $offset + $size )
        : $self->$method( $buffer, $size );
}

my %pointer_value_offset = (
    1 => 0,
    2 => 2**11,
    3 => 2**19 + 2**11,
    4 => 0,
);

sub _decode_pointer {
    my $self      = shift;
    my $ctrl_byte = shift;
    my $offset    = shift;

    my $pointer_size = ( ( $ctrl_byte >> 3 ) & 0b00000011 ) + 1;

    $self->_debug_string( 'Pointer size', $pointer_size )
        if DEBUG;

    my $buffer;
    $self->_read( \$buffer, $offset, $pointer_size );

    $self->_debug_binary( 'Buffer', $buffer )
        if DEBUG;

    my $packed
        = $pointer_size == 4
        ? $buffer
        : ( pack( C => $ctrl_byte & 0b00000111 ) ) . $buffer;

    $packed = $self->_zero_pad_left( $packed, 4 );

    $self->_debug_binary( 'Packed pointer', $packed )
        if DEBUG;

    my $pointer = unpack( 'N' => $packed ) + $self->_pointer_base();
    $pointer += $pointer_value_offset{$pointer_size};

    $self->_debug_string( 'Pointer to', $pointer )
        if DEBUG;

    return ( $pointer, $offset + $pointer_size );
}

sub _decode_utf8_string {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;

    return q{} if $size == 0;

    return Encode::decode( 'utf-8', $buffer, Encode::FB_CROAK );
}

sub _decode_double {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;

    return 0 if $size == 0;

    return $buffer + 0;
}

sub _decode_bytes {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;

    return q{} if $size == 0;

    return $buffer;
}

sub _decode_uint16 {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;

    return $self->_decode_uint( $buffer, $size, 4 );
}

sub _decode_uint32 {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;

    return $self->_decode_uint( $buffer, $size, 4 );
}

sub _decode_map {
    my $self   = shift;
    my $size   = shift;
    my $offset = shift;

    $self->_debug_string( 'Map size', $size )
        if DEBUG;

    my %map;
    for ( 1 .. $size ) {
        ( my $key, $offset ) = $self->decode($offset);
        ( my $val, $offset ) = $self->decode($offset);

        if (DEBUG) {
            $self->_debug_string( "Key $_",   $key );
            $self->_debug_string( "Value $_", $val );
        }

        $map{$key} = $val;
    }

    $self->_debug_structure( 'Decoded map', \%map )
        if DEBUG;

    return wantarray ? ( \%map, $offset ) : \%map;
}

sub _decode_int32 {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;

    return 0 if $size == 0;

    return unpack( 'N!' => $self->_zero_pad_left( $buffer, 4 ) );
}

sub _decode_uint64 {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;

    return $self->_decode_uint( $buffer, $size, 8 );
}

sub _decode_uint128 {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;

    return $self->_decode_uint( $buffer, $size, 16 );
}

sub _decode_uint {
    my $self   = shift;
    my $buffer = shift;
    my $size   = shift;
    my $bytes  = shift;

    if (DEBUG) {
        $self->_debug_string( 'UINT size',  $size );
        $self->_debug_string( 'UINT bytes', $bytes );
        $self->_debug_binary( 'Buffer', $buffer );
    }

    if ( $bytes == 4 ) {
        return 0 if $size == 0;
        return unpack( 'N' => $self->_zero_pad_left( $buffer, $bytes ) );
    }
    else {
        return uint128(0)
            if $size == 0;

        return uint128( bin2bcd( $self->_zero_pad_left( $buffer, 16 ) ) );
    }
}

sub _decode_array {
    my $self   = shift;
    my $size   = shift;
    my $offset = shift;

    $self->_debug_string( 'Array size', $size )
        if DEBUG;

    my @array;
    for ( 1 .. $size ) {
        ( my $val, $offset ) = $self->decode($offset);

        if (DEBUG) {
            $self->_debug_string( "Value $_", $val );
        }

        push @array, $val;
    }

    $self->_debug_structure( 'Decoded array', \@array )
        if DEBUG;

    return wantarray ? ( \@array, $offset ) : \@array;
}

sub _decode_container {
    return MaxMind::DB::Reader::Data::Container->new();
}

sub _decode_end_marker {
    return MaxMind::DB::Reader::Data::EndMarker->new();
}

sub _size_from_ctrl_byte {
    my $self      = shift;
    my $ctrl_byte = shift;
    my $offset    = shift;

    my $size = $ctrl_byte & 0b00011111;
    return ( $size, $offset )
        if $size < 29;

    my $bytes_to_read = $size - 28;

    my $buffer;
    $self->_read( \$buffer, $offset, $bytes_to_read );

    if ( $size == 29 ) {
        $size = 29 + unpack( 'C', $buffer );
    }
    elsif ( $size == 30 ) {
        $size = 285 + unpack( 'n', $buffer );
    }
    else {
        $size = 65821 + unpack( 'N', $self->_zero_pad_left( $buffer, 4 ) );
    }

    return ( $size, $offset + $bytes_to_read );
}

sub _zero_pad_left {
    my $self           = shift;
    my $content        = shift;
    my $desired_length = shift;

    return ( "\x00" x ( $desired_length - length($content) ) ) . $content;
}

__PACKAGE__->meta()->make_immutable();

1;