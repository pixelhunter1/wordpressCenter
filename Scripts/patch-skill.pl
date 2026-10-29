#!/usr/bin/perl
# Patch local a uma skill do upstream, por substituição de texto exacta (sem regex, por isso um
# carácter especial no texto não muda o sentido do patch).
#
#   Scripts/patch-skill.pl <ficheiro> <texto a substituir> <texto novo>
#   Scripts/patch-skill.pl --json <patches.json> <pasta das skills>
#
# Falha quando o alvo desapareceu. Sem isso, uma mudança de redação no upstream deixava o build a
# sair com meia correção e ninguém dava por isso — que é o que o `sed` silencioso fazia antes.
#
# As regras vivem em Runtime/skills/patches.json e são as mesmas que a app aplica depois de trazer
# uma versão nova (SkillUpdates.swift): um sítio para as regras, dois consumidores.
use strict;
use warnings;
use JSON::PP ();

my @args = @ARGV;

if ( @args && $args[0] eq '--json' ) {
    my ( undef, $rules_file, $root ) = @args;
    die "utilização: patch-skill.pl --json <patches.json> <pasta>\n" unless defined $root;
    open my $rh, '<:raw', $rules_file or die "não consegui ler $rules_file: $!\n";
    my $rules = JSON::PP->new->decode( do { local $/; <$rh> } );
    close $rh;
    for my $patch ( @{ $rules->{patches} } ) {
        # Uma regra que apaga texto tem de deixar texto à volta: a app aplica as regras duas vezes numa
        # atualização e só um 'replace' presente prova que a segunda passagem não tem nada a fazer.
        die "✗ a regra de $patch->{skill}/$patch->{file} apaga texto sem âncora: um 'replace' vazio não deixa provas de que já foi aplicada\n"
            if !defined $patch->{replace} || $patch->{replace} eq '';
        # No build a raiz tem todas as skills: um ficheiro que falta é um erro (o upstream mudou o sítio?),
        # não uma regra a ignorar.
        apply( "$root/$patch->{skill}/$patch->{file}", $patch->{find}, $patch->{replace} );
    }
    exit 0;
}

my ( $file, $from, $to ) = @args;
die "utilização: patch-skill.pl <ficheiro> <de> <para>\n" unless defined $to;
apply( $file, $from, $to );

sub apply {
    my ( $file, $from, $to ) = @_;
    die "✗ não existe $file\n" unless -f $file;

    open my $in, '<:raw', $file or die "não consegui ler $file: $!\n";
    local $/;
    my $text = <$in>;
    close $in;

    die "✗ patch local sem alvo em $file\n  esperava: $from\n  (o upstream mudou? ver Runtime/skills/patches.json)\n"
        if index( $text, $from ) < 0;

    my $out = '';
    my $at;
    while ( ( $at = index( $text, $from ) ) >= 0 ) {
        $out .= substr( $text, 0, $at ) . $to;
        $text = substr( $text, $at + length($from) );
    }
    $out .= $text;

    open my $fh, '>:raw', $file or die "não consegui escrever $file: $!\n";
    print $fh $out;
    close $fh;
}
