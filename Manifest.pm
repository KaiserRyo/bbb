package Manifest;
use XML::Bare;
use File::Basename;
use v5.10;
use strict;
no warnings 'experimental';

sub new {
	my ($class, $filename) = @_;

	my $xml = XML::Bare->new(file => $filename);
	my $root = $xml->parse()->{BlackBerry_Backup};

	die "Manifest file corrupt" unless $root;

	my $obj = {
		basedir => dirname($filename),
		root => $root,
	};
	return bless $obj, $class;
}

sub archives {
	my ($self) = @_;

	return $self->calculate_files(map {
		{
			size => $_->{bytesize}->{value},
			id => $_->{id}->{value},
			keyid => $_->{keyid}->{value},
			name => $_->{name}->{value},
			type => $_->{type}->{value},
		};
	} @{$self->{root}->{QnxOSDevice}->{Archives}->{Archive}});
}

sub calculate_files {
	my $self = shift;

	foreach my $a (@_) {
		my $file;
		if ($a->{id} eq 'settings') {
			$file = 'settings.tar';
		} elsif ($a->{id} eq 'systemapps') {
			$file = 'systemapps.app.system';
		} elsif ($a->{id} eq 'media') {
			$file = 'media.tar';
		} elsif ($a->{type} ~~ ['bin', 'data']) {
			$file = $a->{id} . '.app.' . $a->{type};
		}
		$a->{file} = $self->{basedir} . '/Archive/' . $file;
	}
	return @_;
}

1;
