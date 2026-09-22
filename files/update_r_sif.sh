#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# update_r_sif.sh
#
# Actualiza una imagen Apptainer SIF basada en R.
#
# Soporta:
#   --apt   Paquetes Debian
#   --r     Paquetes CRAN
#   --bioc  Paquetes Bioconductor
#
# Utiliza fakeroot, por lo que no requiere sudo.
# ============================================================


# ------------------------------------------------------------
# Configuración
# ------------------------------------------------------------

R_REPO="https://cloud.r-project.org"

# Número de CPUs para compilación de paquetes R.
# Puede modificarse, por ejemplo:
#
#   R_NCPUS=8 ./update_r_sif.sh ...
#
R_NCPUS="${R_NCPUS:-4}"

IMAGE=""

APT_PACKAGES=()
R_PACKAGES=()
BIOC_PACKAGES=()


# ============================================================
# Ayuda
# ============================================================

usage() {

cat <<'EOF'

Actualizador de imágenes R / Apptainer
=======================================

Uso:

  update_r_sif.sh -i IMAGEN [opciones]


OPCIONES

  -i, --image FILE

      Imagen SIF que se desea actualizar.

      La extensión .sif es opcional.


  --apt PKG...

      Instala uno o varios paquetes del sistema Debian
      utilizando apt-get.


  --r PKG...

      Instala uno o varios paquetes de R desde CRAN.


  --bioc PKG...

      Instala uno o varios paquetes de Bioconductor.


  -h, --help

      Muestra esta ayuda.


EJEMPLOS


1. Instalar tidyverse:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --r tidyverse


2. Instalar varios paquetes CRAN:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --r ape phytools tidyverse remotes


3. Instalar librerías Debian:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --apt libxml2-dev libcurl4-openssl-dev libssl-dev


4. Instalar dependencias Debian + paquetes R:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --apt libxml2-dev libcurl4-openssl-dev libssl-dev \
      --r xml2 curl openssl tidyverse


5. Instalar paquetes de Bioconductor:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --bioc DESeq2 edgeR Biostrings


6. Combinar Debian + CRAN + Bioconductor:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --apt libxml2-dev libcurl4-openssl-dev libssl-dev \
      --r ape phytools tidyverse \
      --bioc DESeq2 Biostrings


7. Utilizar 8 CPUs al compilar paquetes R:

  R_NCPUS=8 ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --r tidyverse


FUNCIONAMIENTO

  1. Comprueba que Apptainer y fakeroot funcionan.

  2. Convierte temporalmente:

       imagen.sif
           |
           v
       sandbox/

  3. Instala los paquetes solicitados.

  4. Reconstruye un nuevo SIF.

  5. Conserva la imagen anterior como respaldo.

  6. Sustituye la imagen original solamente si todo terminó
     correctamente.


IMPORTANTE

  El script NO utiliza sudo.

  Fakeroot debe estar configurado correctamente para el usuario.

EOF

}


# ============================================================
# Sin argumentos -> mostrar ayuda
# ============================================================

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi


# ============================================================
# Leer argumentos
# ============================================================

MODE=""

while [[ $# -gt 0 ]]; do

    case "$1" in

        -i|--image)

            if [[ $# -lt 2 ]]; then
                echo "ERROR: falta el nombre de la imagen."
                exit 1
            fi

            IMAGE="$2"
            MODE=""
            shift 2
            ;;


        --apt)

            MODE="apt"
            shift
            ;;


        --r)

            MODE="r"
            shift
            ;;


        --bioc)

            MODE="bioc"
            shift
            ;;


        -h|--help)

            usage
            exit 0
            ;;


        -*)

            echo
            echo "ERROR: opción desconocida:"
            echo
            echo "  $1"
            echo

            usage
            exit 1
            ;;


        *)

            case "$MODE" in

                apt)
                    APT_PACKAGES+=("$1")
                    ;;

                r)
                    R_PACKAGES+=("$1")
                    ;;

                bioc)
                    BIOC_PACKAGES+=("$1")
                    ;;

                *)
                    echo
                    echo "ERROR: argumento inesperado:"
                    echo
                    echo "  $1"
                    echo
                    usage
                    exit 1
                    ;;

            esac

            shift
            ;;

    esac

done


# ============================================================
# Comprobar Apptainer
# ============================================================

if ! command -v apptainer >/dev/null 2>&1; then

    echo
    echo "ERROR: no se encontró el comando apptainer."
    echo

    exit 1

fi


# ============================================================
# Comprobar imagen
# ============================================================

if [[ -z "$IMAGE" ]]; then

    echo
    echo "ERROR: debes especificar una imagen:"
    echo
    echo "  -i imagen.sif"
    echo

    exit 1

fi


# Añadir .sif automáticamente
if [[ "$IMAGE" != *.sif ]]; then
    IMAGE="${IMAGE}.sif"
fi


if [[ ! -f "$IMAGE" ]]; then

    echo
    echo "ERROR: no existe la imagen:"
    echo
    echo "  $IMAGE"
    echo

    exit 1

fi


# ============================================================
# Comprobar que se solicitó alguna instalación
# ============================================================

if [[ ${#APT_PACKAGES[@]} -eq 0 \
   && ${#R_PACKAGES[@]} -eq 0 \
   && ${#BIOC_PACKAGES[@]} -eq 0 ]]; then

    echo
    echo "ERROR: no especificaste ningún paquete."
    echo

    usage
    exit 1

fi


# ============================================================
# Preparar nombres
# ============================================================

DIR="$(dirname "$IMAGE")"
FILE="$(basename "$IMAGE")"
BASENAME="${FILE%.sif}"

TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"

SANDBOX="${DIR}/.${BASENAME}-sandbox-${TIMESTAMP}"

NEW_IMAGE="${DIR}/.${BASENAME}-new-${TIMESTAMP}.sif"

BACKUP="${DIR}/${BASENAME}_${TIMESTAMP}.sif"


# ============================================================
# Función de limpieza
# ============================================================

cleanup() {

    echo

    if [[ -d "$SANDBOX" ]]; then

        echo "Eliminando sandbox temporal..."

        rm -rf "$SANDBOX" || true

    fi


    if [[ -f "$NEW_IMAGE" ]]; then

        echo "Eliminando SIF temporal..."

        rm -f "$NEW_IMAGE" || true

    fi

}


trap cleanup EXIT


# ============================================================
# Comprobar fakeroot
# ============================================================

echo
echo "============================================================"
echo " Comprobando fakeroot"
echo "============================================================"
echo

if ! apptainer exec \
        --fakeroot \
        "$IMAGE" \
        true; then

    echo
    echo "ERROR: fakeroot no funciona correctamente."
    echo
    echo "Comprueba:"
    echo
    echo "  grep \"^${USER}:\" /etc/subuid"
    echo "  grep \"^${USER}:\" /etc/subgid"
    echo
    echo "También puedes probar:"
    echo
    echo "  apptainer exec --fakeroot $IMAGE id"
    echo

    exit 1

fi

echo
echo "Fakeroot: OK"


# ============================================================
# Mostrar resumen
# ============================================================

echo
echo "============================================================"
echo " Actualizador R / Apptainer"
echo "============================================================"

echo
echo "Imagen:"
echo
echo "  $IMAGE"

echo
echo "CPUs para compilación de R:"
echo
echo "  $R_NCPUS"


if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "Paquetes Debian:"

    printf '  - %s\n' "${APT_PACKAGES[@]}"

fi


if [[ ${#R_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "Paquetes CRAN:"

    printf '  - %s\n' "${R_PACKAGES[@]}"

fi


if [[ ${#BIOC_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "Paquetes Bioconductor:"

    printf '  - %s\n' "${BIOC_PACKAGES[@]}"

fi


echo


# ============================================================
# 1. SIF -> sandbox
# ============================================================

echo "============================================================"
echo "1. Creando sandbox"
echo "============================================================"
echo

apptainer build \
    --fakeroot \
    --sandbox \
    "$SANDBOX" \
    "$IMAGE"


# ============================================================
# 2. Paquetes Debian
# ============================================================

if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "============================================================"
    echo "2. Instalando paquetes Debian"
    echo "============================================================"
    echo


    apptainer exec \
        --fakeroot \
        --writable \
        "$SANDBOX" \
        env DEBIAN_FRONTEND=noninteractive \
        apt-get update


    apptainer exec \
        --fakeroot \
        --writable \
        "$SANDBOX" \
        env DEBIAN_FRONTEND=noninteractive \
        apt-get install \
        -y \
        --no-install-recommends \
        "${APT_PACKAGES[@]}"


    echo
    echo "Limpiando caché de APT..."


    apptainer exec \
        --fakeroot \
        --writable \
        "$SANDBOX" \
        apt-get clean


    apptainer exec \
        --fakeroot \
        --writable \
        "$SANDBOX" \
        rm -rf /var/lib/apt/lists/*

fi


# ============================================================
# 3. CRAN
# ============================================================

if [[ ${#R_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "============================================================"
    echo "3. Instalando paquetes CRAN"
    echo "============================================================"


    for PACKAGE in "${R_PACKAGES[@]}"; do

        # Validar nombre
        if [[ ! "$PACKAGE" =~ ^[A-Za-z0-9._]+$ ]]; then

            echo
            echo "ERROR: nombre de paquete R no válido:"
            echo
            echo "  $PACKAGE"

            exit 1

        fi


        echo
        echo "------------------------------------------------------------"
        echo "CRAN :: $PACKAGE"
        echo "------------------------------------------------------------"
        echo


        apptainer exec \
            --fakeroot \
            --writable \
            "$SANDBOX" \
            Rscript -e "
                options(
                    repos = c(
                        CRAN = '$R_REPO'
                    ),
                    Ncpus = $R_NCPUS
                )

                install.packages(
                    '$PACKAGE',
                    Ncpus = $R_NCPUS
                )
            "

    done

fi


# ============================================================
# 4. Bioconductor
# ============================================================

if [[ ${#BIOC_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "============================================================"
    echo "4. Instalando paquetes Bioconductor"
    echo "============================================================"
    echo


    echo "Comprobando BiocManager..."
    echo


    apptainer exec \
        --fakeroot \
        --writable \
        "$SANDBOX" \
        Rscript -e "
            options(
                repos = c(
                    CRAN = '$R_REPO'
                ),
                Ncpus = $R_NCPUS
            )

            if (!requireNamespace(
                    'BiocManager',
                    quietly = TRUE
                )) {

                install.packages(
                    'BiocManager',
                    Ncpus = $R_NCPUS
                )

            }
        "


    for PACKAGE in "${BIOC_PACKAGES[@]}"; do

        if [[ ! "$PACKAGE" =~ ^[A-Za-z0-9._]+$ ]]; then

            echo
            echo "ERROR: nombre de paquete Bioconductor no válido:"
            echo
            echo "  $PACKAGE"

            exit 1

        fi


        echo
        echo "------------------------------------------------------------"
        echo "Bioconductor :: $PACKAGE"
        echo "------------------------------------------------------------"
        echo


        apptainer exec \
            --fakeroot \
            --writable \
            "$SANDBOX" \
            Rscript -e "
                options(
                    Ncpus = $R_NCPUS
                )

                BiocManager::install(
                    '$PACKAGE',
                    ask = FALSE,
                    update = FALSE,
                    Ncpus = $R_NCPUS
                )
            "

    done

fi


# ============================================================
# 5. Verificar R
# ============================================================

echo
echo "============================================================"
echo "5. Verificando R"
echo "============================================================"
echo


apptainer exec \
    "$SANDBOX" \
    R --version


echo
echo "Library paths:"
echo


apptainer exec \
    "$SANDBOX" \
    Rscript -e 'print(.libPaths())'


# ============================================================
# 6. Verificar paquetes solicitados
# ============================================================

if [[ ${#R_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "Paquetes CRAN solicitados:"
    echo

    for PACKAGE in "${R_PACKAGES[@]}"; do

        apptainer exec \
            "$SANDBOX" \
            Rscript -e "
                if (!requireNamespace(
                        '$PACKAGE',
                        quietly = TRUE
                    )) {

                    stop(
                        'El paquete $PACKAGE no quedó instalado'
                    )

                }

                cat(
                    '$PACKAGE ',
                    as.character(
                        packageVersion('$PACKAGE')
                    ),
                    '\n'
                )
            "

    done

fi


if [[ ${#BIOC_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "Paquetes Bioconductor solicitados:"
    echo

    for PACKAGE in "${BIOC_PACKAGES[@]}"; do

        apptainer exec \
            "$SANDBOX" \
            Rscript -e "
                if (!requireNamespace(
                        '$PACKAGE',
                        quietly = TRUE
                    )) {

                    stop(
                        'El paquete $PACKAGE no quedó instalado'
                    )

                }

                cat(
                    '$PACKAGE ',
                    as.character(
                        packageVersion('$PACKAGE')
                    ),
                    '\n'
                )
            "

    done

fi


# ============================================================
# 7. Construir nuevo SIF
# ============================================================

echo
echo "============================================================"
echo "6. Construyendo nuevo SIF"
echo "============================================================"
echo


apptainer build \
    --fakeroot \
    "$NEW_IMAGE" \
    "$SANDBOX"


# ============================================================
# 8. Verificar nuevo SIF
# ============================================================

echo
echo "============================================================"
echo "7. Verificando nuevo SIF"
echo "============================================================"
echo


apptainer exec \
    "$NEW_IMAGE" \
    Rscript -e 'cat("R:", R.version.string, "\n")'


# ============================================================
# 9. Backup
# ============================================================

echo
echo "============================================================"
echo "8. Guardando imagen anterior"
echo "============================================================"
echo


echo "Backup:"
echo
echo "  $BACKUP"
echo


mv "$IMAGE" "$BACKUP"


# ============================================================
# 10. Activar nueva imagen
# ============================================================

echo "Activando nueva imagen..."
echo


mv "$NEW_IMAGE" "$IMAGE"


# ============================================================
# 11. Eliminar sandbox
# ============================================================

rm -rf "$SANDBOX"


# Desactivar trap porque terminamos correctamente
trap - EXIT


# ============================================================
# Resultado
# ============================================================

echo
echo "============================================================"
echo " ACTUALIZACIÓN COMPLETADA"
echo "============================================================"

echo
echo "Imagen actualizada:"
echo
echo "  $IMAGE"

echo
echo "Imagen anterior:"
echo
echo "  $BACKUP"

echo
echo "R:"
echo

apptainer exec \
    "$IMAGE" \
    Rscript -e 'cat(R.version.string, "\n")'

echo
