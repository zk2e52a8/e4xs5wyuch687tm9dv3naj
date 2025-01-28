#!/bin/bash

# Este script recopila identificadores de miniaturas de fichas en zonatmo.com según sus etiquetas, para generar un filtro de bloqueo compatible con uBlock

# NOTE Sobre la obtención de la url
# Se usa "$dominio_tmo/library" (BIBLIOTECA) para listar entradas filtrando sus tags y flags
# Permanecer en la página 1 genera un formato de url no deseado; es necesario avanzar en la lista
# Debe eliminarse el número final, que corresponde a la página actual
# Es importante ordenar por "Creación" para evitar detectar duplicados prematuramente y ordenar cronologicamente (para los reinicios de los filtros)

dominio_tmo="zonatmo.com"
URLs=(
	# Flags:Seinen Tags:+Ecchi
 	"https://$dominio_tmo/library?order_item=creation&order_dir=desc&demography=seinen&filter_by=title&genders%5B0%5D=6&_pg=1&page="
	# Flags:Shounen Tags:+Ecchi
 	"https://$dominio_tmo/library?order_item=creation&order_dir=desc&demography=shounen&filter_by=title&genders%5B0%5D=6&_pg=1&page="
	# Flags:Seinen,Erótico
 	"https://$dominio_tmo/library?order_item=creation&order_dir=desc&demography=seinen&filter_by=title&erotic=true&_pg=1&page="
	# Flags:Shounen,Erótico
 	"https://$dominio_tmo/library?order_item=creation&order_dir=desc&demography=shounen&filter_by=title&erotic=true&_pg=1&page="
	# Tags:+Ecchi,+Vida escolar
 	"https://$dominio_tmo/library?order_item=creation&order_dir=desc&filter_by=title&genders%5B0%5D=6&genders%5B1%5D=26&_pg=1&page="
	# Tags:+Girls Love
 	"https://$dominio_tmo/library?order_item=creation&order_dir=desc&filter_by=title&genders%5B0%5D=17&_pg=1&page="
	# Flags:Kodomo
	"https://$dominio_tmo/library?order_item=creation&order_dir=desc&demography=kodomo&filter_by=title&_pg=1&page="
)

# Carpeta en la que se guardará el filtro
carpeta_filtro="$GITHUB_WORKSPACE"
# Carpeta para almacenar los archivos (uno por url) de identificadores, para limitar los reescaneos
carpeta_ids="$GITHUB_WORKSPACE/ids_TMO"

# Reinicio de filtros (las fichas pueden ser actualizadas), el primer número índica los días
limite_reset_completo=$((90 * 24 * 3600)) # Reiniciar todos los filtros
limite_reset_suave=$((7 * 24 * 3600)) # Reiniciar las últimas fichas añadidas (ver $num_fichas_recortar)
num_fichas_recortar=120 # Número de fichas recientes a recortar en el reset suave. Hay 24 en cada página

# Archivos para almacenar las fechas de los últimos reinicios de los filtros
archivo_timestamp_completo="$carpeta_ids/RESET_completo.timestamp"
archivo_timestamp_suave="$carpeta_ids/RESET_suave.timestamp"

# Tiempo de espera entre descargas exitosas, para evitar el bloqueo por scraping
pausa="20"

# Límite de reintentos fallidos de descarga
tiempo_espera="300" # En segundos
max_intentos="24" # Lo que equivale a un total de 2 horas

#################### Fin de la configuración

fecha_actual=$(date +%s)

# Leer los timestamps y calcular las diferencias de tiempo
ultimo_reset_completo=$(cat "$archivo_timestamp_completo" 2>/dev/null || echo 0)
ultimo_reset_suave=$(cat "$archivo_timestamp_suave" 2>/dev/null || echo 0)
diff_reset_completo=$(($fecha_actual - $ultimo_reset_completo))
diff_reset_suave=$(($fecha_actual - $ultimo_reset_suave))

# Determinar el modo reset
modo_reset="no"
if [ "$1" == "RESET" ]; then
	modo_reset="completo"
	echo "Se ha ejecutado el script con el argumento 'RESET', activando el modo reset"
elif [ "$diff_reset_completo" -gt "$limite_reset_completo" ]; then
	modo_reset="completo"
	echo "Se ha superado el límite, se activará el reset completo y se volverán a descargar todas las fichas"
elif [ "$diff_reset_suave" -gt "$limite_reset_suave" ]; then
	modo_reset="suave"
	echo "Se ha superado el límite, se activará el reset suave y se volverán a descargar (si es pertinente) las últimas $num_fichas_recortar fichas previamente guardadas de cada url base"
fi

# Crear las carpetas necesarias
mkdir -p "$carpeta_filtro" "$carpeta_ids"
# Carpeta para archivos temporales
directorio_temp="$(mktemp -d)"
# Archivo temporal global para unificar identificadores de todas las URLs procesadas
ids_unificados="$directorio_temp/ids_unificados.txt"

# Asegurar que se limpien los archivos temporales al finalizar
trap 'rm -r "$directorio_temp"' EXIT

intentos_descarga=0

#####

# NOTE cul dejó de funcionar por un endurecimiento de las medidas anti-scraping

# Requiere "npm"
# https://pptr.dev/

echo "Instalando dependencias..."
npm install --prefix "$directorio_temp" puppeteer puppeteer-extra puppeteer-extra-plugin-stealth > /dev/null

# Archivo temporal para el javascript
puppeteer_script="$directorio_temp/puppeteer_scraper.js"
# Escribir el script
cat <<'EOF' > "$puppeteer_script"
// Importar bibliotecas
const puppeteer = require('puppeteer-extra'); // Navegador web basado en chromium
const StealthPlugin = require('puppeteer-extra-plugin-stealth'); // Plugin para evitar detección anti-scraping
const readline = require('readline'); // Permite leer entradas desde la consola (las URLs enviadas desde bash)

puppeteer.use(StealthPlugin()); // Activar el plugin anti-scraping

(async () => {
	// Iniciar el navegador sin gui
	const navegador = await puppeteer.launch({
		headless: "new",
		args: ['--no-sandbox'] // Evitar conflictos con el sandboxing
	});

	// Preparar la interfaz para recibir URLs desde el otro script
	const interfazLectura = readline.createInterface({ input: process.stdin });
	console.log("PUPPETEER_READY");

	// Esperar a recibir URLs y procesarlas (una por una)
	for await (const url of interfazLectura) {
		let pagina;
		try {
			// Abrir nueva pestaña en el navegador
			pagina = await navegador.newPage();

			// Bloquear la descarga de elementos innecesarios
			await pagina.setRequestInterception(true);
			pagina.on('request', (request) => {
				// No cargar imágenes, fuentes ni estilos visuales. # ALERT Potencialmente problemático con el anti-scraping
				if (['image', 'font', 'stylesheet'].includes(request.resourceType())) {
					request.abort();
				} else {
					request.continue(); //
				}
			});

			// Cargar la url. Esperar solo hasta que el DOM esté cargado, y un máximo de 15seg
			await pagina.goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });

			// Obtener el contenido HTML
			const htmlCompleto = await pagina.content();

			// Codificar el resultado a base64 para evitar problemas con el formato
			const base64Content = Buffer.from(htmlCompleto).toString('base64');
			console.log(`SUCCESS:${base64Content}`); // Imprimirlo para que el script Bash lo capture

		} catch (error) {
			console.log(`ERROR:${error.message}`); // Capturar y mostrar cualquier error durante el proceso
		} finally {
			if (pagina) await pagina.close(); // Al finalizar, cerrar la página/pestaña para liberar recursos
		}
	}

	// Cerrar el navegador si se desconecta de la fuente de URLs desde readline
	await navegador.close();
})();
EOF

# Iniciar puppeteer como un coproceso
# "coproc" ejecuta un comando en segundo plano y asigna descriptores para leer y escribir en ese proceso
coproc PUPPETEER_PROC { node "$puppeteer_script"; }

# Asignar los descriptores de archivo del coproceso a variables más fáciles de manejar
PUPPETEER_OUT=${PUPPETEER_PROC[0]}  # Para leer la salida del proceso puppeteer
PUPPETEER_IN=${PUPPETEER_PROC[1]}   # Para enviarle datos a puppeteer
PUPPETEER_PID=$PUPPETEER_PROC_PID   # Obtener el ID del proceso de puppeteer para monitorearlo y detenerlo

# Esperar a que se inicialice correctamente
if ! read -u $PUPPETEER_OUT PUPPETEER_STATUS; then
	echo "Error iniciando puppeteer"
	exit 1
fi

# Asegurar que puppeteer se cierre al terminar
trap 'kill -SIGTERM $PUPPETEER_PID' EXIT

verificar_puppeteer() {
    if ! kill -0 $PUPPETEER_PID 2>/dev/null; then
        echo "Error: Puppeteer se cerró. Abortando..."
        exit 1
    fi
}

#####

descargar_pagina() {
	while true; do
 		verificar_puppeteer
		# Enviar url a descargar
		echo "$url_completa" >&$PUPPETEER_IN

		# Intentar leer la respuesta, con un tiempo de espera máximo de 30 segundos
		if read -t 30 -u $PUPPETEER_OUT respuesta; then
			if [[ "$respuesta" == SUCCESS:* ]]; then
				# Obtener el contenido de la página y decodificarlo
 				contenido_pagina=$(base64 -d <<< "${respuesta#SUCCESS:}")
				echo "Página $numero_pagina descargada con éxito"
				break
			else
				echo "Error de Puppeteer: ${respuesta#ERROR:}"
			fi
		else
			echo "Se agotó el tiempo de espera para la comunicación con Puppeteer"
		fi

		# Reintentos
		intentos_descarga=$((intentos_descarga + 1))
		if [ $intentos_descarga -ge $max_intentos ]; then
			echo "Error tras $max_intentos intentos. Abortando..."
			exit 1
		else
			echo "Intento fallido nº$intentos_descarga"
			sleep $tiempo_espera
		fi
	done
}

procesar_identificadores() {
	# Verificar si hay identificadores
	if [[ -z $nuevos_identificadores ]]; then
		if [[ $numero_pagina -eq 1 ]]; then
			echo "No hay resultados válidos en la página 1"
			echo "Puede que haya un error en la url o que el patrón a procesar haya cambiado"
			echo "Abortando el script"
			exit 1
		else
			echo "No hay resultados válidos en la página $numero_pagina, se asume que se llegó al final"
			return 1
		fi
	fi

	# Si el script se ejecuta con reset completo, omitir la verificación de duplicados
	if [[ "$modo_reset" == "completo" ]]; then
		echo "$nuevos_identificadores" >> "$archivo_ids_temporal"
		return 0
	fi

	# Verificar si hay al menos un id nuevo, de ser el caso guardarlos todos y continuar con la url
	# NOTE No debe verificarse al revés (si hay algún duplicado), ya que pueden haber duplicados en la misma url base
    if ! grep -qxFf "$archivo_ids_temporal" <<< "$nuevos_identificadores"; then
        echo "$nuevos_identificadores" >> "$archivo_ids_temporal"
        return 0
    else
        echo "La página $numero_pagina solo contiene identificadores conocidos"
        return 1
    fi
}

# Procesar cada url
for url_base in "${URLs[@]}"; do
	numero_pagina=0

	# Convertir la url en un nombre de archivo para almacenar los ids, usando solo caracteres simples
	archivo_ids_original="$carpeta_ids/$(echo "${url_base##*/}" | LC_ALL=C tr -sc '[:alnum:]' '-' | sed -e 's/^-*//' -e 's/-*$//').txt"
	archivo_ids_temporal="$directorio_temp/archivo_ids_temporal.txt"

	# Crear un archivo ids si no existe
	touch "$archivo_ids_original"

	# Copiar el archivo de ids de la url actual al archivo temporal, siempre que no se ejecute con el reset completo
	if [[ "$modo_reset" != "completo" ]]; then
		cp "$archivo_ids_original" "$archivo_ids_temporal"
	fi

	# Si se activa el reset suave, recortar las fichas más recientes importadas en el archivo temporal
	if [[ "$modo_reset" == "suave" ]]; then
		head -n -"$num_fichas_recortar" "$archivo_ids_temporal" 2>/dev/null > "$archivo_ids_temporal.tmp"
		mv "$archivo_ids_temporal.tmp" "$archivo_ids_temporal"
    fi

	echo; echo "Iniciando descargas para: $url_base"

	# Procesar todas las páginas de la url base actual
	while true; do
		# Incrementar el número de página
		numero_pagina=$((numero_pagina + 1))

		# Construir la url completa
		url_completa="${url_base}${numero_pagina}"

		sleep $pausa

		# Descargar y verificar la descarga de la página
		descargar_pagina

		# Buscar y extraer los identificadores
 		nuevos_identificadores=$(echo "$contenido_pagina" | grep -Po 'book-thumbnail-\K\d+(?=">)')

		# Procesar ids Si la salida no es 0, guardar ids y terminar con la url base
		if ! procesar_identificadores; then
			# Agregar los nuevos identificadores al archivo unificado
			cat "$archivo_ids_temporal" >> "$ids_unificados"

			# Eliminar duplicados, invertir el orden (el orden cronologico es clave para reset_suave), y guardar los nuevos ids
			awk '!visto[$0]++' "$archivo_ids_temporal" | tac >> "$archivo_ids_original"

			rm "$archivo_ids_temporal"
			break
		fi
	done
done

# Todos los archivos de ids originales actualizados, actualizar el timestamp del archivo reset completo
if [ "$modo_reset" == "completo" ]; then
	echo "$fecha_actual" > "$archivo_timestamp_completo"
elif [ "$modo_reset" == "suave" ]; then
	echo "$fecha_actual" > "$archivo_timestamp_suave"
fi

#####

echo "Descargas completadas, procesando filtro..."

# Ordenar el archivo temporal global y eliminar duplicados (LC_ALL=C lo establece en ascii raw)
LC_ALL=C sort --unique -o "$ids_unificados" "$ids_unificados"

# Formatear los identificadores para uBlock, añadiendo prefijos y sufijos específicos
base_filtro="$directorio_temp/base_filtro.txt"
sed "s|^|$dominio_tmo##.book-thumbnail-|; s|$|.book.thumbnail|" "$ids_unificados" > "$base_filtro"

# Añadir la cabecera y guardar el filtro
{	echo "! Title: Filtros para TMO"
	echo "! Last modified: $(TZ="UTC" date +"%a, %d %b %Y %H:%M:%S %z")"
 	echo "! Expires: 12 hours"
	echo
	cat "$base_filtro"
} > "$carpeta_filtro/filtro_ublock_TMO.txt"

echo "Finalizado"

# Copia del workflow de gitub (notese que hay que configurar "secrets.WG_CONFIG")
# .github/workflows/ejecutar_script.yml

# name: Ejecutar script
#
# on:
#   schedule:
#     - cron: '0 */12 * * *'
#   workflow_dispatch:
#
# jobs:
#   ejecutar_script:
#     runs-on: ubuntu-latest
#
#     steps:
#       - name: Clonar repositorio
#         uses: actions/checkout@v4
#
#       - name: Instalar WireGuard
#         run: sudo apt-get update && sudo apt-get install -y wireguard-tools
#
#       - name: Configurar WireGuard
#         run: |
#           sudo mkdir -p /etc/wireguard/
#           echo "${{ secrets.WG_CONFIG }}" | sudo tee /etc/wireguard/wg0.conf > /dev/null
#           sudo chmod 600 /etc/wireguard/wg0.conf
#
#       - name: Iniciar conexión WireGuard
#         run: sudo wg-quick up wg0
#
#       - name: Verificar conexión WireGuard
#         run: |
#           if ! sudo wg show wg0 2>&1 | grep -q 'latest handshake'; then
#             echo "::error::La conexión WireGuard falló. La clave de WireGuard podría estar obsoleta."
#             exit 1
#           fi
#
#       - name: Configurar Node.js
#         uses: actions/setup-node@v4
#
#       - name: Configurar git
#         run: |
#           git config --global user.name "github-actions"
#           git config --global user.email "actions@github.com"
#
#       - name: Ejecutar script
#         run: |
#           chmod +x ./script_ublock_TMO.sh
#           ./script_ublock_TMO.sh
#
#       - name: Detener conexión WireGuard
#         if: always()
#         run: sudo wg-quick down wg0
#
#       - name: Subir cambios
#         run: |
#           git add -A
#           git commit -m "Actualizar filtro" || echo "Sin cambios"
#           git pull origin main --rebase
#           git push origin main
