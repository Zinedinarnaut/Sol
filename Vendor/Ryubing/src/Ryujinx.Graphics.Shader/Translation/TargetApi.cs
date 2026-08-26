namespace Ryujinx.Graphics.Shader.Translation
{
    public enum TargetApi
    {
        OpenGL,
        Vulkan,
        Metal,
    }

    public static class TargetApiExtensions
    {
        /// <summary>
        /// Metal consumes Ryujinx's SPIR-V output through SolMetal's pinned
        /// SPIRV-Cross translator. It therefore shares Vulkan's descriptor-set
        /// and coordinate conventions even though no Vulkan API is involved.
        /// </summary>
        public static bool UsesSpirvLayout(this TargetApi api)
        {
            return api is TargetApi.Vulkan or TargetApi.Metal;
        }
    }
}
